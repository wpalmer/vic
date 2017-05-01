require 'bundler/setup'
require 'cloudformation-ruby-dsl/cfntemplate'
require 'cloudformation-ruby-dsl/spotprice'
require 'cloudformation-ruby-dsl/table'
require 'diw/config'

# First, we extend the cloudformation-ruby-dsl TemplateDSL class, to add in some
# utility methods, and parameter handling
class TemplateDSL < JsonObjectDSL
	def exec!()
		if ARGV[0] == "parameters"
			STDOUT.puts(JSON.generate((@dict[:Parameters] || []).map {|k,definition|
				if definition[:Default].nil? || definition[:NoEcho]
					{
						ParameterKey: k,
						ParameterValue: (
							if $cfg.has_var?(k)
								$cfg.var(k)
							else
								self.parameters[k]
							end
						)
					}
				end
			}.to_a.compact))
		else
			cfn(self)
		end
	end

	def prefixed_name(name)
		[$cfg.environment, name].join('-')
	end

	def name_tag(name, options = {})
		{ :Key => "Name", :Value => prefixed_name(name) }.
		merge(options)
	end

	def export_value(name)
		{ :Name => [stack_name, name].join(':') }
	end

	def import_value(external_stack_name, name, environment: nil)
		{
			"Fn::ImportValue" => [
				$cfg.stacks.var(external_stack_name.to_sym, environment: environment),
				name
			].join(':')
		}
	end

	def load_from_file(filename, *vargs, **hargs)
		file = File.open(filename)

		begin
			# Figure out what the file extension is and process accordingly.
			contents = case File.extname(filename)
				when ".rb"; eval(file.read, nil, filename)
				when ".json"; JSON.load(file)
				when ".yaml"; YAML::load(file)
				else; raise("Do not recognize extension of #{filename}.")
			end
		ensure
			file.close
		end

		if contents.is_a? Proc
			args[:block] = Proc.new if block_given?
			contents = instance_exec(*vargs, **hargs, &contents)
		end
	end
end

# Define "S3Frame", which quacks like a diw/config "Frame", so that we can read
# secret data from S3 (using AWS credentials)
class S3Frame
	def initialize(bucket, s3prefix = "", configprefix = [])
		@bucket = bucket
		@s3prefix = s3prefix
		@configprefix = configprefix
		@section_cache = {}
		@var_cache = {}
	end

	def s3client
		return @s3client unless @s3client.nil?
		@s3client = Aws::S3::Client.new()
	end

	def strip_prefix(section_path)
		return section_path if @configprefix.length == 0
		return nil if section_path.length < @configprefix.length
		return nil if section_path[0..@configprefix.length - 1] != @configprefix
		section_path[(@configprefix.length)..(section_path.length - 1)]
	end

	def has_section?(path)
		return !!@section_cache[path.join "."] if @section_cache.has_key?(path.join ".")

		key = strip_prefix(path)
		return false if key.nil?
		if key.length == 0 then
			@section_cache[path.join "."] = { }
			return true
		end

		begin
			s3client.head_object(
				bucket: @bucket,
				key: @s3prefix + key.join("/") + "/",
				if_match: "d41d8cd98f00b204e9800998ecf8427e"
			)
			@section_cache[path.join "."] = { }
			return true
		rescue Aws::S3::Errors::NotFound
			@section_cache[path.join "."] = false
			return false
		end
	end

	def set_section(path, vars = {})
		raise NoMethodError.new("set_section not implemented for S3Frame")
	end

	def has_var?(name)
		return !@var_cache[name].nil? if @var_cache.has_key?(name)

		begin
			s3client.head_object(
				bucket: @bucket,
				key: @s3prefix + name.to_s
			)
			@var_cache[name] = :NOT_FILLED
			return true
		rescue Aws::S3::Errors::NotFound
			@var_cache[name] = nil
			return false
		end
	end

	def get_var(name)
		return @var_cache[name] if @var_cache.has_key?(name) && @var_cache[name] != :NOT_FILLED

		result = s3client.get_object(
			bucket: @bucket,
			key: @s3prefix + name.to_s
		)

		@var_cache[name] = result.body.string.strip
	end

	def set_var(name, value)
		raise NoMethodError.new("set_var not implemented for S3Frame")
	end

	def has_section_var?(section_path, name)
		return false if !has_section?(section_path)
		return !@section_cache[section_path.join "."][name].nil? if @section_cache[section_path.join "."].has_key?(name)

		key = strip_prefix(section_path)
		begin
			s3client.head_object(
				bucket: @bucket,
				key: @s3prefix + (key + [ name.to_s ]).join("/")
			)
			@section_cache[section_path.join "."][name] = :NOT_FILLED
			return true
		rescue Aws::S3::Errors::NotFound
			@section_cache[section_path.join "."][name] = nil
			return false
		end
	end

	def get_section_var(section_path, name)
		return nil if !has_section?(section_path)
		if @section_cache[section_path.join "."].has_key?(name) &&
			 @section_cache[section_path.join "."][name] != :NOT_FILLED
			return @section_cache[section_path.join "."][name]
		end

		key = strip_prefix(section_path)
		result = s3client.get_object(
			bucket: @bucket,
			key: @s3prefix + (key + [ name.to_s ]).join("/")
		)
		@section_cache[section_path.join "."][name] = result.body.string.strip
	end

	def set_section_var(section_path, name, value)
		raise NoMethodError.new("set_section_var not implemented for S3Frame")
	end
end

# Define the default $cfg.environment and $cfg.stacks.<stack name> to obtain
# environment-specific stack names based on a generic template name.
$cfg = ::DIW::Config::Config.new do
	var \
		environment: 'live',
		stacks: Proc.new {|cfg|
			Module.new {
			def self.method_missing(method, *args)
				return super if args.length > 0
				self.var(method.to_s.gsub(/_/, '-'))
			end
			def self.var(name, environment: nil)
				environment = $cfg.environment if environment.nil?

				case name
				when /-(?:dns|registry)$/
					name
				else
					[environment, name].join('-')
				end
			end
		}}
end

# Override $cfg.environment based on the --environment argument (if applicable)
$cfg.push do
	ARGV.slice_before(/^--/).each do |name, value|
		case name
		when /--environment=(.*)$/
			var environment: $1
		end
	end
end

# Pull in defaults and environment-specific configuration
require ('./_default') if File.exists?('./_default.rb')
require ('./_' + $cfg.environment) if File.exists?('./_' + $cfg.environment + '.rb')

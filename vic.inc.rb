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

	def import_stack_export(external_stack_name, name, environment: nil)
		{
			"Fn::ImportValue" => [
				$cfg.stacks.var(external_stack_name.to_sym, environment: environment),
				name
			].join(':')
		}
	end

	def import_stack_output(external_stack_name, name, environment: nil)
		@stack_values = {} if @stack_values.nil?

		stack_name = $cfg.stacks.var(external_stack_name.to_sym, environment: environment)
		if @stack_values.has_key? stack_name
			unless @stack_values[stack_name].has_key? name
				raise "Unknown stack value #{stack_name}::#{name}"
			end

			return @stack_values[stack_name][name]
		end

		cfnclient = Aws::CloudFormation::Client.new()
		stack = cfnclient.describe_stacks({stack_name: stack_name}).stacks[0]
		@stack_values[stack_name] = {}
		stack.outputs.each{|output|
			@stack_values[stack_name][output.output_key] = output.output_value
		}

		return self.import_stack_output(external_stack_name, name, environment: environment)
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

	def define_output(resource_name, resource_type, attribute, spec, export_default)
		unless spec.is_a? Hash
			spec = attribute.to_s if spec == true
			spec = {:ShortName => spec}
		end

		name = nil
		description = nil

		name = spec[:Name].to_s if spec.has_key?(:Name)
		description = spec[:Description].to_s if spec.has_key?(:Description)

		if spec.has_key?(:ShortName)
			compact_name = spec[:ShortName].to_s.split(/\s/).map(&:capitalize).join('').gsub(/[^_a-zA-Z0-9]/, '')
			name = resource_name.to_s + compact_name unless spec.has_key?(:Name)
		end

		if description.nil?
			resource_description = resource_name.to_s

			if resource_name.to_s.end_with? resource_type.split('::').last
				resource_description = (
					resource_name[0..-((resource_type.split('::').last.length)+1)] +
					" " +
					resource_type.split('::').last.
						gsub(/(.)([A-Z][^A-Z])/,'\1 \2').
						gsub(/([^A-Z])([A-Z])/,'\1 \2').
						squeeze(' ').
						gsub(/([A-Z]) ([A-Z])/, '\1\2')
				)
			end

			short_description = attribute.to_s
			if spec.has_key?(:ShortDescription)
				short_description = spec[:ShortDescription].to_s
			elsif spec.has_key?(:ShortName)
				short_description = spec[:ShortName].to_s
			end

			description = "The #{short_description} of the #{resource_description}"
		end

		name = attribute.to_s if name.nil?
		export = if export_default then export_value(name) else nil end
		if spec.has_key?(:Export)
			if !!spec[:Export] == spec[:Export]
				export = nil if !spec[:Export]
			else
				export = spec[:Export].to_s
			end
		end

		if attribute == :Ref
			value = ref(resource_name.to_s)
		else
			value = get_att(resource_name.to_s, attribute.to_s)
		end

		output name, (
			{}.merge(
				{:Value => value}
			).merge(
				(if description.nil? then {} else {:Description => description} end)
			).merge(
				(if export.nil? then {} else {:Export => export} end)
			)
		)
	end

	alias resource_orig resource
	def resource(name, options)
		if options.has_key?(:Output)
			type = if options.has_key?(:Type) then options[:Type] else nil end

			export_default = false
			attributes = options[:Output]
			if options[:Output].is_a? Hash
				if options[:Output].has_key? :Export then export_default = options[:Output][:Export] end
				if options[:Output].has_key? :Attributes then attributes = options[:Output][:Attributes] end
			end

			if attributes.is_a? Array
				attributes.each do |attribute|
					if attribute.is_a? Hash and attribute.has_key?(:Attribute)
						spec = attribute
						attribute = spec[:Attribute]
						spec.delete(:Attribute)
						define_output(name, type, attribute, spec, export_default)
					else
						spec = if attribute == :Ref then "Id" else attribute.to_s end
						define_output(name, type, attribute, spec, export_default)
					end
				end
			elsif attributes.is_a? Hash
				attributes.each do |attribute, spec|
					next if attribute == :Export and attributes == options[:Output]
					define_output(name, type, attribute, spec, export_default)
				end
			elsif !!attributes == attributes
				define_output(name, type, :Ref, "Id", export_default)
			else
				define_output(name, type, :Ref, attributes, export_default)
			end
		end

		resource_orig(name, options.tap{|o| o.delete(:Output) })
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

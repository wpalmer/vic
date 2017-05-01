$cfg.push do
	var fooVar: "fooValue", # $cfg.fooVar
	    barVar: "barValue"  # $cfg.barVar

	var derivedVar: Proc.new do |cfg|
		cfg.fooVar # => run-time value of $cfg.fooVar
	end

	section :fooSection do
		var fooSubVar: "fooSubValue", # $cfg.fooSection.fooSubVar
		    barSubVar: "barSubValue"  # $cfg.fooSection.barSubVar
	end
end

$cfg.push S3Frame.new(
	"my-bucket-name-#{$cfg.environment}-credentials",
	"my-path-prefix/",
	[:credentials]
) # $cfg.credentials.foo to read from s3://my-bucket-name/my-path-prefix/foo

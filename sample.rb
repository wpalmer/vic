require './vic.inc'
# A Sample template. Create this stack via:
# ./vic.sh --create sample

template do
	value :AWSTemplateFormatVersion => '2010-09-09'
	value :Description => %{sample template}

	resource 'VPC',
		:Type => 'AWS::EC2::VPC',
		:Properties => {
			:CidrBlock => '10.0.0.0/16',
			:EnableDnsHostnames => true,
			:EnableDnsSupport => true,
			:Tags => [
				name_tag('vpc'),
				{:Key => 'sample-extra', :Value => $cfg.environment},
				{:Key => 'sample-extra-stack', :Value => $cfg.stacks.sample}
			]
		}
end.exec!

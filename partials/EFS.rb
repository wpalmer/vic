Proc.new do |
	name,
	resourcePrefix: '',
	securityGroups: nil,
	subnets: []
|
	resource "#{resourcePrefix}Filesystem",
		:Type => 'AWS::EFS::FileSystem',
		:Properties => {
			:FileSystemTags => [
				name_tag(name)
			]
		}

	Hash[*(
		subnets.each_with_index.map{|(k,v),i|
			v.nil? ? [ (i + 1).to_s, k ] : [ k.to_s, v ]
		}.flatten
	)].each do |resourceSuffix, subnet|
		resource "#{resourcePrefix}Mount#{resourceSuffix}",
			:Type => 'AWS::EFS::MountTarget',
			:Properties => {
				:FileSystemId => ref("#{resourcePrefix}Filesystem"),
				:SubnetId => subnet,
				:SecurityGroups => securityGroups
			}
	end

	output "#{resourcePrefix}EFSId",
		:Description => "The Id of the #{resourcePrefix} EFS Filesystem".squeeze(' '),
		:Value => ref("#{resourcePrefix}Filesystem"),
		:Export => export_value("#{resourcePrefix}EFSId")

end

Proc.new do |
	users: {} # {"<username>": ["<key>", {key: "<key>", entry: "<authorized_keys line>", command: "<command>", ...}]}
	          # command implies restricted environment
|
	lines = users.map do |username,keys|
		keys.map do |spec|
			spec = {entry: spec} unless spec.is_a?(Hash)
			if spec.has_key?(:command)
				spec = {restrict: true}.merge(spec)
			end

			username + ":" + (spec.has_key?(:entry) ? spec[:entry] :
				(
					[
						[
							(spec.has_key?(:restrict) && spec[:restrict]) ? "restrict" : nil,
							spec.has_key?(:agentForwarding) ? (spec[:agentForwarding] ? "" : "no-") + "agent-forwarding" : nil,
							(spec.has_key?(:certAuthority) && spec[:certAuthority]) ? "cert-authority" : nil,
							spec.has_key?(:command) ? "command=\"#{spec[:command].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:environment) ? "environment=\"#{spec[:environment].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:from) ? "from=\"#{spec[:from].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:permitopen) ? "permitopen=\"#{spec[:permitopen].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:portForwarding) ? (spec[:portForwarding] ? "" : "no-") + "port-forwarding" : nil,
							spec.has_key?(:principals) ? "principals=\"#{spec[:principals].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:pty) ? (spec[:pty] ? "" : "no-") + "pty" : nil,
							spec.has_key?(:tunnel) ? "tunnel=\"#{spec[:tunnel].gsub(/([\"])/, '\\\\\1')}\"" : nil,
							spec.has_key?(:userRc) ? (spec[:userRc] ? "" : "no-") + "user-rc" : nil,
							spec.has_key?(:x11Forwarding) ? (spec[:x11Forwarding] ? "" : "no-") + "X11-forwarding" : nil,
						].compact.join(","),
						spec.has_key?(:type) ? spec[:type] : nil,
						spec.has_key?(:key) ? spec[:key] : nil,
						spec.has_key?(:comment) ? spec[:comment] : nil
					].compact.join(" ")
				)
			) + " added by CloudFormationInit"
		end
	end.flatten

	{
		"commands" => {
			"01_update_authorized_keys" => {
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {users: users, lines: lines.sort}
					#!/bin/bash -xe
					USERNAMES=( {{join(" ", *locals[:users].keys.sort)}} )
					for username in "${USERNAMES[@]}"; do
						user_home="$( getent passwd "$username" | cut -d: -f6 )"
						user_id="$( getent passwd "$username" | cut -d: -f3 )"
						user_group_id="$( getent passwd "$username" | cut -d: -f4 )"

						mkdir --mode=0700 -p "${user_home}/.ssh"
						chown "${user_id}:${user_group_id}" "${user_home}/.ssh"
						if [[ -f "${user_home}/.ssh/authorized_keys" ]]; then
							sed -i '/ added by CloudFormationInit$/d' "${user_home}/.ssh/authorized_keys"
						fi

						sed -n "/^${username}:/{ s/^[^:]*://;p; }" \
							>> "${user_home}/.ssh/authorized_keys" \
							<<SSHLINES
{{join("\\n", *locals[:lines])}}

SSHLINES
					done
				END_SH
				)
			}
		}
	}
end

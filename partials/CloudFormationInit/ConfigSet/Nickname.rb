Proc.new do |
	# The "default nickname" will be set to <purpose>.<instance-id>.<environment>, eg: maintenance.i-b33ff00d.test
	# "Nickname" functionality based on:
	# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-hostname.html#set-hostname-shell
	purpose: 'unknown', # (probably short) human-readable name for the instnace
	template: '$NICKNAME_PURPOSE.$EC2_INSTANCE_ID.$VIC_ENVIRONMENT', # to use as an interpreted bash string
	template_shell: nil # to use as an interpreted bash string, only for the shell (defaults to value of template)
|
	{
		"commands" => {
			"01_tweak_bashrc" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, "")
					#!/bin/bash -xe
					[[ -e /etc/bashrc.nickname_orig ]] || exit 0
					exit 1
				END_SH
				),
				"command" => interpolate(<<-'END_SH'.gsub(/^\s+/, ""), {purpose: purpose, template: template, template_shell: template_shell, environment: $cfg.environment}
					#!/bin/bash -xe
					[[ -e /etc/bashrc.nickname_orig ]] || cp /etc/bashrc /etc/bashrc.nickname_orig
					sed '
						/^\s*if \[ "$PS1" \]; then/{
							a \
							  EC2_INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"\
							  NICKNAME_PURPOSE='\''{{locals[:purpose]}}'\''\
							  VIC_ENVIRONMENT='\''{{locals[:environment]}}'\''\
							  export NICKNAME="{{locals[:template]}}"\
							  NICKNAME_SHELL="{{locals[:template_shell].gsub(/\\/, '\\\\\\') || locals[:template]}}"
							;
						}
						/^\s*\[ "$PS1" = /{
							c \
							  [ "$PS1" = "\\\\s-\\\\v\\\\\$ " ] && PS1="[\\u@$NICKNAME_SHELL \\W]\\$ ";
							;
						}
					' /etc/bashrc.nickname_orig > /etc/bashrc

					echo 'printf "\033]0;%s@%s:%s\007" "${USER}" "${NICKNAME%%.*}" "${PWD/#$HOME/~}"' > /etc/sysconfig/bash-prompt-xterm
					chmod a+x /etc/sysconfig/bash-prompt-xterm

					echo 'printf "\033]0;%s@%s:%s\033\\" "${USER}" "${NICKNAME%%.*}" "${PWD/#$HOME/~}"' > /etc/sysconfig/bash-prompt-screen
					chmod a+x /etc/sysconfig/bash-prompt-screen
				END_SH
				)
			}
		}
	}
end

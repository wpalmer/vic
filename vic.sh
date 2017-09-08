#!/bin/bash
set -e
set -o pipefail
base="$(dirname "${BASH_SOURCE[0]}")"
TEMP="$(mktemp --tmpdir -d 'vic.XXXXXXXXXX')"
[ -n "$TEMP" -a -d "$TEMP" -a -w "$TEMP" ] || exit 1
_cleanup(){ rm -rf "$TEMP"; }
trap _cleanup EXIT

usage(){
	printf 'Usage: vic --<operation> [--environment=<prefix>] <template[.rb]> [stack name]\n'
}

help(){
	usage
	printf '\n'
	printf '\t--environment=<prefix> Add <prefix> to stack names, and load configuration from _<prefix>.rb\n'
	printf '\t--create               Create a new stack\n'
	printf '\t--update               Update an existing stack\n'
	printf '\t--update-empty         Update metadata of an existing stack, but not the resources\n'
	printf '\t--update-immediate     Update an existing stack, without asking for confirmation\n'
	printf '\t--update-empty-all     Try to update the metadata of all existing stacks\n'
	printf '\t--output=diff          Rather than manipulating CloudFormation, output a diff of the template json\n'
	printf '\t--output=template      Rather than talking to CloudFormation, output the template json\n'
	printf '\t--output=parameters    Rather than talking to CloudFormation, output the parameter json\n'
	printf '\t--status               Output the current status of the stack\n'
	printf '\t--wtf                  Output the event log of the most-recent failed-looking stack\n'
	printf '\t--wait                 Check stack status repeatedly, until it reaches a non-transitional state\n'
	printf '\t--verbose | -v         Output additional information when relevant\n'
}

if [[ -f "$base/.vic.env" ]]; then
	grep -q '^AWS_PROFILE=' "$base/.vic.env" &&
	AWS_PROFILE="$(
		sed -n '/^AWS_PROFILE=/{
			s/^AWS_PROFILE=//;
			p;
			q;
		}' <"$base/.vic.env"
	)"
	export AWS_PROFILE
fi

if [[ -n "$AWS_DEFAULT_PROFILE" ]] && [[ -z "$AWS_PROFILE" ]]; then
	AWS_PROFILE="$AWS_DEFAULT_PROFILE"
	export AWS_PROFILE
fi
if [[ -n "$AWS_PROFILE" ]] && [[ -z "$AWS_DEFAULT_PROFILE" ]]; then
	AWS_DEFAULT_PROFILE="$AWS_PROFILE"
	export AWS_DEFAULT_PROFILE
fi

if [[ -n "$AWS_DEFAULT_REGION" ]] && [[ -z "$AWS_REGION" ]]; then
	AWS_REGION="$AWS_DEFAULT_REGION"
	export AWS_REGION
fi
if [[ -n "$AWS_REGION" ]] && [[ -z "$AWS_DEFAULT_REGION" ]]; then
	AWS_DEFAULT_REGION="$AWS_REGION"
	export AWS_DEFAULT_REGION
fi

extra_environment_args=()
[[ -n "$AWS_PROFILE" ]] && extra_environment_args=(
	"${extra_environment_args[@]}"
	-e AWS_PROFILE="$AWS_PROFILE"
)

for envvar in \
	AWS_ACCESS_KEY_ID \
	AWS_SECRET_ACCESS_KEY \
	AWS_SESSION_TOKEN \
	AWS_DEFAULT_REGION \
	AWS_REGION \
	AWS_DEFAULT_PROFILE \
	AWS_PROFILE \
	AWS_CONFIG_FILE
do
	[[ -n "${!envvar}" ]] && extra_environment_args=(
		"${extra_environment_args[@]}"
		-e $envvar="${!envvar}"
	)
done

[[ -d "$HOME/.aws" ]] && extra_environment_args=(
	"${extra_environment_args[@]}"
	-v "$HOME/.aws:/root/.aws"
)

did_template=0
did_stack=0
did_environment=0
do_wait=0
do_verbose=0
op=
output=stack
environment=live
while [[ $# -gt 0 ]]; do
	arg="$1"; shift
	case "$arg" in
		--create)
			op=create
			;;
		--output=*)
			op=output
			output="${arg#*=}"
			;;
		--update-immediate)
			op=update
			;;
		--update-empty)
			op=empty-changeset
			;;
		--update-empty-all)
			op=update-empty-all
			;;
		--update)
			op=changeset
			;;
		--validate)
			op=validate
			;;
		--graph)
			op=graph
			;;
		--status)
			op=status
			;;
		--wait)
			do_wait=1
			;;
		--wtf)
			op=wtf
			;;
		--verbose|-v)
			do_verbose=1
			;;
		--environment=*)
			environment="${arg#*=}"
			did_environment=1
			;;
		--help)
			help
			exit 0
			;;
		-*)
			printf 'Unknown argument %s\n' "$arg" >&2
			usage >&2
			exit 1
			;;
		*)
			if [[ $did_template -ne 1 ]]; then
				template="$arg"
				did_template=1
				[[ $did_stack -eq 1 ]] || stack="${arg%.rb}"
			elif [[ $did_stack -ne 1 ]]; then
				stack="$arg"
				did_stack=1
			fi
			;;
	esac
done

if [[ -z "$op" ]]; then
	if [[ $do_wait -eq 1 ]]; then
		op=wait
	else
		usage >&2
		exit 1
	fi
fi

if [[ "$op" = "update-empty-all" ]]; then
	for stack in "$base"/*.rb; do
		stack="${stack##*/}"
		[[ "${stack#_}" = "${stack}" ]] || continue
		[[ "${stack%inc.rb}" = "${stack}" ]] || continue

		echo "${stack}"
		"$base/vic.sh" --update-empty --environment="${environment}" "${stack}" || true
	done
	exit
fi

if [[ "$op" = "graph" ]]; then
	mkdir -p "$base/.graph" || exit 1
	stacks=( )
	env_hash="$(
		sha1sum $base/_*.rb | awk '{print $1}' |
		sha1sum | awk '{print $1}'
	)"

	printf 'digraph dependencies {
		overlap = false;
		splines = true;
		concentrate = true;
		start = '$RANDOM';
		node[shape=record,style=filled,fillcolor=gray95]
		edge[dir=back, arrowtail=empty]
	'
	for template in *.rb; do
		[[ "${template#_}" = "${template}" ]] || continue
		hash="$(sha1sum "${template}" | awk '{print $1}')"
		stacks=( "${stacks[@]}" "${template%.rb}.$env_hash.$hash.json" )
		if [[ ! -e "$base/.graph/${template%.rb}.$env_hash.$hash.json" ]]; then
			echo "Compiling $template..." >&2
			if ! "${BASH_SOURCE[0]}" \
				--environment="$environment" \
				--output=template \
				"$template" \
			> "$base/.graph/${template%.rb}.$env_hash.$hash.json"
			then
				rm -f "$base/.graph/${template%.rb}.$env_hash.$hash.json"
				exit 1
			fi
		fi

		canonical="${template%.rb}"
		if
			[[ "${canonical%-registry}" = "${canonical}" ]] && \
			(
				[[ "${canonical%-dns}" = "${canonical}" ]] ||
				[[ "${canonical%-private-dns}" != "${canonical}" ]]
			)
		then
			canonical="${environment}-${canonical}"
		fi

		printf '%s\n' '
				"'"${canonical}"'"[label = "{'"$(
		jq -r < "$base/.graph/${template%.rb}.$env_hash.$hash.json" \
		--arg template "${canonical}" \
		'
			(
				[ "<template>" + $template ] +
				(
					[
						.Outputs?//{} |
						to_entries[] |
						select(.value.Export?) |
						(.value.Export?.Name?//"") |
						sub(".*:"; "") |
						("<" + . + ">" + .)
					] |
					unique | []
				)
			) | join("|")
			')"'}"]'
		jq -r < "$base/.graph/${template%.rb}.$env_hash.$hash.json" \
		--arg template "${canonical}" '
			[..|.["Fn::ImportValue"]?|values|sub(":.*"; ":template")]|
			unique|
			.[]|

			(
				"\"" +
					(.|sub(":"; "\":\"")) +
				"\" -> \"" +
					$template +
				"\""
			)
		'
	done
	printf '%s' '
		}
	'
	exit
fi

if [[ $did_stack -eq 0 ]] && [[ -n "$stack" ]]; then
	case "$stack" in
		*-private-dns)
			stack_name="${environment}-${stack}"
			;;
		*-registry|*-dns)
			if [[ "$environment" != "live" ]]; then
				printf "implicitly-global stack '%s' requires --environment=live\n" \
					"$stack" >&2
				exit 1
			fi
			stack_name="$stack"
			;;
		*)
			stack_name="${environment}-${stack}"
			;;
	esac
else
	stack_name="$stack"
fi

if [[ "$op" = "wtf" ]]; then
	if [[ -z "$stack_name" ]]; then
		if [[ $did_environment -eq 1 ]]; then
			filter_environment="$environment"
		else
			filter_environment=
		fi

		stack_name="$(
			aws cloudformation list-stacks \
				--stack-status-filter '[
					"CREATE_FAILED",
					"ROLLBACK_IN_PROGRESS",
					"ROLLBACK_FAILED",
					"ROLLBACK_COMPLETE",
					"UPDATE_ROLLBACK_IN_PROGRESS",
					"UPDATE_ROLLBACK_FAILED",
					"UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS",
					"UPDATE_ROLLBACK_COMPLETE"
				]' |
			jq -r --arg environment "$filter_environment" '
				[
					.StackSummaries[] |
					select(
						($environment == "") or
						(.StackName | startswith( $environment + "-" )) or
						(
							($environment == "live") and
							(.StackName | endswith("-dns")) and
							((.StackName | endswith("-private-dns"))|not)
						)
					)
				] |
				sort_by( .LastUpdatedTime ) | last |
				.StackName // ""
			'
		)"

		if [[ -z "$stack_name" ]]; then
			printf 'No failed stacks detected\n' >&2
			exit 1
		fi
	fi

	echo "STACK: $stack_name"
	aws cloudformation describe-stack-events \
		--stack-name="$stack_name" |
	jq -r '[
		.StackEvents[] |
		select(
			.ResourceStatusReason and
			(
				[
					[
						"CREATE_FAILED",
						"ROLLBACK_IN_PROGRESS",
						"ROLLBACK_FAILED",
						"ROLLBACK_COMPLETE",
						"UPDATE_ROLLBACK_IN_PROGRESS",
						"UPDATE_ROLLBACK_FAILED",
						"UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS",
						"UPDATE_ROLLBACK_COMPLETE"
					][] == .ResourceStatus
				] | any
			)
		)
	] |
	reverse[] |
	[
		.Timestamp,
		.ResourceType,
		.ResourceStatus + ":",
		.ResourceStatusReason
	] | join(" ")'
	exit 0
fi

if [[ $did_template -ne 1 ]]; then
	usage >&2
	exit 1
fi

status(){
	local stack_name="$1"
	local output="$(aws cloudformation describe-stacks --stack-name="${stack_name}")"
	[[ -n "$output" ]] || return 1

	local status="$( printf '%s\n' "$output" | jq -r '.Stacks[].StackStatus//""' )"
	printf '%s\n' "$status"

	if [[ $do_verbose -eq 1 ]]; then
		local reason="$( printf '%s\n' "$output" | jq -r '.Stacks[].StackStatusReason//""' )"
		[[ -z "$reason" ]] || printf '%s\n' "$reason"
	fi
}

wait_stack(){
	local stack_name="$1"
	local status=
	local n=0
	local reason=
	while true; do
		[[ $n -eq 0 ]] || sleep $(( $n + 1 ))

		local output="$(aws cloudformation describe-stacks --stack-name="${stack_name}")"
		[[ -n "$output" ]] || return 1
		status="$( printf '%s\n' "$output" | jq -r '.Stacks[].StackStatus//""' )"
		reason="$( printf '%s\n' "$output" | jq -r '.Stacks[].StackStatusReason//""' )"

		case "$status" in
			*_IN_PROGRESS)
				if [[ $n -eq 0 ]]; then n=1; else n=$(( $n * 2 )); fi
				[[ $n -lt 30 ]] || n=30
				printf '.' >&2
				continue
				;;
			*_COMPLETE|*_FAILED)
				printf '%s\n' "$status"
				if [[ $do_verbose -eq 1 ]] && [[ -n "$reason" ]]; then
					printf '%s\n' "$reason"
				fi
				return 0
				;;
			*)
				printf 'Unknown status: %s\n' "$status" >&2
				return 1
				;;
		esac
	done
}

if [[ "$op" = "status" ]]; then
	status="$(status "${stack_name}")"
	[[ -n "$status" ]] || exit 1

	printf '%s\n' "$status"
	exit 0
fi

if [[ "$op" = "wait" ]]; then
	wait_stack "${stack_name}"
	exit $?
fi

if [[ "${template%.rb}" != "$template" ]] && [[ -f "${environment}-${template}" ]]; then
	template="${environment}-${template}"
elif [[ -f "${environment}-${template}.rb" ]]; then
	template="${environment}-${template}.rb"
elif [[ "${template%.rb}" != "$template" ]] && [[ -f "${template}" ]]; then
	template="${template}"
else
	template="${template}.rb"
fi

extra=()
if [[ "$op" = "create" ]]; then
	extra=( --disable-rollback )
fi

expand(){
	local template="$1"; shift
	docker run --rm \
		"${extra_environment_args[@]}" \
		-v "$PWD:/cfn" wpalmer/cloudformation-ruby-dsl \
		"$template" \
		"expand" \
		--nopretty \
		--stack-name "$stack_name" \
		--environment="$environment"
}

parameters(){
	local template="$1"; shift
	docker run --rm \
		"${extra_environment_args[@]}" \
		-v "$PWD:/cfn" wpalmer/cloudformation-ruby-dsl \
		"$template" \
		"parameters" \
		--stack-name "$stack_name" \
		--environment="$environment"
}

cf_template="$( expand "./${template}" )"
if [[ "$output" = "template" ]]; then
	printf '%s\n' "$cf_template"
	exit 0
fi

if [[ "$output" = "diff" ]]; then
	cf_old_template="$(aws cloudformation get-template --stack="$stack_name")"
	if [[ -z "$cf_old_template" ]]; then
		exit 1
	fi

	diff -u \
		--label="cloudformation/$stack_name" <(jq --sort-keys .TemplateBody <<<"$cf_old_template") \
		--label="local/$stack_name" <(jq --sort-keys . <<<"$cf_template") |
	less -F
	exit 0
fi

cf_parameters="$( parameters "./${template}" )"
if [[ "$output" = "parameters" ]]; then
	printf '%s\n' "$cf_parameters"
	exit 0
fi

case "$op" in
	create|update|changeset|empty-changeset)
		if [[ "$op" = "changeset" || "$op" = "empty-changeset" ]]; then
			action=create-change-set
			extra=(
				"${extra[@]}"
				--change-set-name="build-cli-$(date +'%Y%m%d%H%M%S')"
			)
		else
			action=${op}-stack
		fi

		cf_template="$(
			jq -c <<<"$cf_template" \
				--arg git_id "$(
					if which git 2>/dev/null >&2; then
						if git rev-parse HEAD 2>/dev/null >&2; then
							printf '%s%s' \
								"$(git rev-parse HEAD)" \
								"$(
									[[
										-n "$(git status --porcelain --untracked-files=no)" ||
										-n "$(git status --porcelain "$template")"
										]] &&
									echo -n "+dirty"
								)"
						else
							printf 'untracked'
						fi
					else
						printf 'unknown'
					fi
				)" \
				--arg stack "$stack_name" \
				--arg environment "$environment" \
				--arg vic_source_file "$template" \
				--arg cfn_template_sha256 "$(
					jq --sort-keys . <<<"$cf_template" |
					sha256sum |
					awk '{print $1}'
				)" \
				--arg cfn_parameters_sha256 "$(
					jq --sort-keys . <<<"$cf_parameters" |
					sha256sum |
					awk '{print $1}'
				)" \
				'
					. * {"Outputs": {
						"MetaCfnTemplateSha256": {
							"Description": "The SHA256 hash of the template (uglified, sorted, excluding Meta outputs)",
							"Value": $cfn_template_sha256,
							"Export": {"Name": ($stack + ":meta:cfnTemplateSha256")}
						},
						"MetaCfnParametersSha256": {
							"Description": "The SHA256 hash of the parameters (uglified, sorted)",
							"Value": $cfn_parameters_sha256,
							"Export": {"Name": ($stack + ":meta:cfnParametersSha256")}
						},
						"MetaGitId": {
							"Description": "The git commit id of the checkout 'vic' was run from",
							"Value": $git_id,
							"Export": {"Name": ($stack + ":meta:gitId")}
						},
						"MetaVicEnvironment": {
							"Description": "The vic 'environment' parameter, used to select presets",
							"Value": $environment,
							"Export": {"Name": ($stack + ":meta:vicEnvironment")}
						},
						"MetaVicSourceFile": {
							"Description": "The main file from which the template was generated",
							"Value": $vic_source_file,
							"Export": {"Name": ($stack + ":meta:vicSourceFile")}
						}
					}}
				'
		)"

		extra_tags=(
			--tags "$(
				jq --null-input \
					--arg environment "$environment" \
					'[
						{
							"Key": "vic:environment",
							"Value": $environment
						}
					]'
			)"
		)

		extra=(
			"${extra[@]}"
			"${extra_tags[@]}"
			--stack-name="${stack_name}"
			--parameters="$cf_parameters"
			--capabilities='["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]'
		)
		;;
	validate)
		action=validate-template
		;;
esac

output="$(
	aws cloudformation "${action}" \
		"${extra[@]}" \
		--template-body="$cf_template" \
)"

if [[ "$op" = "changeset" || "$op" = "empty-changeset" ]]; then
	change_set_arn="$( printf '%s\n' "$output" | jq -r .Id )"
	if [[ -z "$change_set_arn" ]]; then
		printf '%s\n' "$output" | jq
		exit 1
	fi

	status=
	change_set_description=
	while true; do
		change_set_description="$(
			aws cloudformation describe-change-set \
				--change-set-name="$change_set_arn"
		)"
		status="$( printf '%s\n' "$change_set_description" | jq -r .Status )"

		if
			[[ "$status" = "CREATE_PENDING" ]] ||
			[[ "$status" = "CREATE_IN_PROGRESS" ]]
		then
			printf '.' >&2
			sleep 2
			continue
		fi

		break
	done

	if [[ "$status" != "CREATE_COMPLETE" ]]; then
		printf '%s\n' "$status" >&2
		if [[ $do_verbose -gt 0 ]]; then
			printf '%s\n' "$change_set_description" >&2
		fi

		aws cloudformation delete-change-set \
			--change-set-name="$change_set_arn"
		exit 1
	fi

	change_count="$(
		printf '%s\n' "$change_set_description" |
		jq -r '.Changes | length'
	)"
	printf '%s\n' "$change_set_description" | jq -r '
		.Changes[] |
		if .Type == "Resource" then
			(
				if .ResourceChange.Action == "Modify" then
					(
						.ResourceChange.Action + "[Replacement=" +
							.ResourceChange.Replacement +
						"]"
					)
				else
					.ResourceChange.Action
				end + " " +
				.ResourceChange.LogicalResourceId + " " +
				"(" + .ResourceChange.ResourceType + ")"
			)
		else
			.
		end
	'

	reply=
	if [[ $change_count -lt 1 ]]; then
		if [[ "$op" = "empty-changeset" ]]; then
			reply=y
		else
			printf 'No changes.\n' >&2
			reply=n
		fi
	elif [[ "$op" = "empty-changeset" ]]; then
		printf 'Unexpected changes.\n' >&2
		reply=n
	else
		while true; do
			read -p 'Do you want to apply this change set (y/n/v)? ' reply

			case "$reply" in
				y|n)
					break
					;;
				v)
					printf '%s\n' "$change_set_description" | jq .
					continue
					;;
				*)
					continue
					;;
			esac
		done
	fi

	if [[ "$reply" = "y" ]]; then
		printf 'Applying update...\n' >&2
		aws cloudformation execute-change-set \
			--change-set-name="$change_set_arn"
		if [[ $do_wait -eq 1 ]]; then
			printf '.' >&2
			sleep 5
			wait_stack "${stack_name}"
			exit $?
		fi
	else
		aws cloudformation delete-change-set \
			--change-set-name="$change_set_arn"
	fi
else
	if [[ $do_wait -eq 1 ]]; then
		printf '.' >&2
		sleep 5
		wait_stack "${stack_name}"
		exit $?
	else
		printf '%s\n' "$output" | jq .
	fi
fi

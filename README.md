## Vic Formation

A convenience-wrapper for managing
[AWS CloudFormation](http://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) Templates,
built with [`cloudformation-ruby-dsl`](https://github.com/bazaarvoice/cloudformation-ruby-dsl).
Within the ruby templates, variables can be referenced using [`config-ruby-dsl`](https://github.com/wpalmer/config-ruby-dsl).

This project is intended to be cloned and used as a base for managing your own CloudFormation templates.

The primary interface is a bash script, `vic.sh`. It requires:

 - [Docker](https://www.docker.com/)
 - The [`aws`](https://aws.amazon.com/cli/) cli
 - [`jq`](https://stedolan.github.io/jq/)

The basic usage is:

    ./vic.sh --<action> [--environment=staging] <template.rb>

See `./vic.sh --help` for more information.

Key features exposed via `vic.sh`:

 - Create/Update CloudFormation stacks based on preprocessed templates

 - Automatically fill stack "parameters" based on configuration variables

 - Define/Utilize stack "partials" to accomplish common goals (eg: automatically
   attaching EFS/EBS volumes)

 - Define "environments" by creating a file `_<environment name>.rb`, which will
   automatically load configuration overrides based on the `--environment=`
   argument.

#### Templates

See the documentation for
[`cloudformation-ruby-dsl`](https://github.com/bazaarvoice/cloudformation-ruby-dsl).
Create your templates in the root of this tree, and begin them with:

    require './vic.inc'

#### Environments
Which stack is to be referenced is determined based on the `--environment`
parameter, which also causes the stack name and certain tags to become prefixed
with the environment's name. For example, using `--environment=staging` with the
template `primary-instances` will perform operations on the stack
`staging-primary-instances` and pull in extra configuration from the
`_staging.rb` ruby file.

Some types of stack are "global". These exist independently of any environment,
either because they refer to resources which *cannot* be sanely duplicated
across environments (such as DNS domain names), or because they logically
*should* be sharing resources across environments (such as ECR repositories,
which, for sanity, promote images to production by tagging an existing `staging`
image with a new `live` tag). Stacks named to hint that they contain such
resources can only be defined in the "live" environment, and receive no prefix.
The "global" stacks are those with names ending in "-dns" or "-registry".

# goc - <ins>**g**</ins>it<ins>**o**</ins>ps-<ins>**c**</ins>ompose

> _**GitOps principles without the need for complex GitOps tooling**_

<hr/>

_gitops-compose_ allows you to manage all your compose stacks in a central repostiory and use GitOps principles to deploy the changes on your fleet:

- Automatically deploy changes on the compose files
- less than 300 LoC in plain bash
- One repository for multiple machines
- Mix and match stacks based on configuration files
- Simple onboarding for new machines
- Get notified about changes

This project is ideally combined with some sort of automatic dependency update mechanism, like Renovate or Dependabot.

## Setup

There are essentially only two steps towards using _gitops-compose_:

1. Prepare the repository containing all the stack configuration files by adding `goc.yaml`
2. Deploy the goc-controller and point it to the repository

### `goc.yaml` configuration file

This file is the main entrypoint into the provided repository. Here you define the paths and settings for each given stack _gitops-compose_ should manage.

The file is incredibly lightweight and follows this structure:

```yaml
stacks:
  foo:
    # Path of compose stack relative to the repository root
    repo_dir: repo/path/to/foo

    # Path is relative to the GOC_WORKSPACE defined on the controller
    target_dir: foo/

    # Optional: name of compose file in the compose stack directory
    compose_file: compose.yaml

  bar:
    # Path of compose stack relative to the repository root
    repo_dir: repo/path/to/bar

    # Path is relative to the GOC_WORKSPACE defined on the controller
    target_dir: bar/

    # Optional: name of compose file in the compose stack directory
    compose_file: compose.prod.yaml
```

### goc controller deployment

You can run the _gitops-compose_ controller either as a plain docker container or using it's own compose stack.

To avoid secrets in process outputs or the compose file itself, it's recommanded to create a `.env` file. You can find an example in [.env.example](.env.example) and all the options below.

> [!IMPORTANT]
> !! Please note that the mounted stack directory needs to be the same on the host and container !!

#### docker compose stack

See [compose.yaml](compose.yaml) for an example. Copy the contents into a `compose.yaml` and start the stack.

#### docker container

```sh
docker run -d --name=goc-controller --restart=unless-stopped --env-file=.env --volume /foo/bar/stacks:/foo/bar/stacks --volume /var/run/docker.sock:/var/run/docker.sock ghcr.io/laugmanuel/goc:main
```

## environment variables

| variable                    | description                                                                                                                      | required | default  |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | -------- | -------- |
| GOC_WORKSPACE               | Working directory for running docker compose stacks. This directory must exist on the host and will hold all compose stack files | yes      | -        |
| GOC_REPOSITORY              | Git repository URL. If the repository is private, you can use a personal access token and prefix the URL with `<PAT>@`           | yes      | -        |
| GOC_REPOSITORY_BRANCH       | default branch for GOC to read from                                                                                              | no       | main     |
| GOC_REPOSITORY_CONFIG       | path to `goc.yaml` in the repository                                                                                             | no       | goc.yaml |
| GOC_REPOSITORY_RESET        | switch to enable hard resets. This is only needed if the remote repository is subject to rewrites in the history                 | no       | false    |
| GOC_INTERVAL                | check interval in seconds                                                                                                        | no       | 30       |
| GOC_NOTIFICATIONS           | enable or disable notifications using [AppRise](https://github.com/caronc/apprise)                                               | no       | false    |
| GOC_NOTIFICATION_URL        | AppRise notification URL                                                                                                         | no       | -        |
| GOC_NOTIFICATION_START_STOP | send a notification on start and stop of goc controller                                                                          | no       | false    |
| GOC_DRY_RUN                 | enable dry run mode. **Note: this <ins>does clone</ins> the repository but <ins>doesn't copy files or restart services</ins>**   | no       | false    |
| DEBUG                       | Enable debug output in the log                                                                                                   | no       | false    |

## temporarily ignore stack

Sometimes it might be required to temporarily ignore a given stack directory without disabling _gitops-compose_ completely.

For that purpose, you can just create a `.gocignore` file in the target directory.
If that file is present, _gitops-compose_ wil ignore the stack and sent a notification on each interval to keep you informed about that fact.

## Limitations

> [!NOTE]
>
> - **secret management**: `goc` currently does not support any kind of secret management. If you need secrets for your applications, make sure to place them seperatly in an `.env` file for the given stack.
> - **custom permissions**: `goc` just copies the files from the repository _as is_. Neither the owner nor any other attributes are altered.

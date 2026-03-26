---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-05
---

# HyperFleet Configuration Standard

## Overview

This document defines the standard approach for configuration loading, merging, and override rules across all HyperFleet applications. This ensures consistent, predictable configuration behavior across all repositories.

## Configuration behavior

When configuring applications there are multiple options for data sources:
- Using files 
  - Single or multiple files allowed (in YAML format)
  - Good for complex object hierarchies (arrays, complex objects)
- Using command-line arguments
  - Good for interactive execution (e.g. during development, `--help`)
- Using environment variables
  - More secure for parameters like credentials
  - Easy to operate in environments like Kubernetes
- Remote configuration
  - Centralized configuration

For HyperFleet applications we want to offer flexibility and predictability for developers and providers who will operate the solution.
- HyperFleet applications will use data sources with this override precedence
  1. **Command-line flags** (highest priority)
  2. **Environment variables**
  3. **Configuration files** 
  4. Defaults
- All the configuration options must be documented explicitly in a `docs/config.md` document in the repository
- Current "merged" configuration should be displayed at boot time, or exposed to be queried (e.g. using an `/config` endpoint)

All options can be set using all data sources, with some exceptions:
- The location for a config file is defined by a command-line parameter `--config` or environment variable only.
- Some libraries used by the applications (e.g broker or OTEL) will require their specific files and/or environment variables
  - It doesn't make sense to offer multiple ways to configure these
- Any other exception should be documented in `docs/config.md`

## Config properties syntax

Since each data source has different syntax rules, we need to establish a convention for config properties:
- Properties in files must be in snake_case
- Properties should form a hierarchy of single word paths
  - E.g to represent the property `app.name`
   - As a command-line parameter it will be `--app-name`
   - As an environment variable it will be `HYPERFLEET_APP_NAME`
     - In YAML files it can be a nested property
```yaml
app:
  name: myapp
```


Beware: Snake case property names can cause confusion:
- e.g. how to represent `APP_SERVER_PORT` in a YAML, is it `app.server.port`, `app.server_port` or even `app_server.port`
- All should resolve to the same end config setting for the application


## Standard Configuration File Paths

Config files for HyperFleet applications must be in YAML format

The config file location is flexible and can be determined by:
1. Path specified via `--config` flag (if provided)
2. Path specified via `HYPERFLEET_CONFIG` environment variable
3. Default values
  - production: `/etc/hyperfleet/config.yaml`
  - development: `./configs/config.yaml`

The first file found is used. If no config file is found, the application continues with flags and environment variables only.

Some applications may work with multiple configuration files, for example the adapter framework can use two config files:
- General application configuration, typically non functional parameters (technical configuration)
- Business specific configuration (e.g. the AdapterConfig configuration)
  - Specifying the file to load should use a configuration key such as `adapter.config` (`--adapter-config`, `HYPERFLEET_ADAPTER_CONFIG`)
  - Values for these business configuration will only be loaded from files, there is no need to override from command line nor environment variables

## Environment Variable Convention

Rules: 
- All letters must be uppercase
- All environment variables for HyperFleet applications should be prefixed with `HYPERFLEET_`. 
  - This makes it easier to identify them and avoids collision with other properties.
  - The exception would be for those environment variables that are used by 3rd party libraries directly (e.g. OpenTelemetry lib)
- Nested properties are separated by the `_` character.
  - e.g. `HYPERFLEET_<PATH>_<TO>_<PROPERTY>`

### Examples
```bash
# General format
HYPERFLEET_APP_NAME="my-api"
HYPERFLEET_SERVER_PORT=9000
HYPERFLEET_DATABASE_HOST="db.example.com"
```

## Command-Line Flag Convention

 Rules
1. **Lowercase**: All letters must be lowercase
2. **Kebab-case**: Use hyphens (`-`) to separate words
3. **Hierarchical**: Use section prefix for nested fields (e.g., `--app-name`, `--server-port`)
4. **Short flags**: Common flags should have single-letter shortcuts

```
--<section>-<field>
```


### Standard Flags

#### Global Flags (all applications)
```
--config <path>              # Config file path
--name, -n <string>          # component name (REQUIRED)
--version, -v <string>       # Display version information
```

#### Server Flags
```
--server-host <string>       # Server bind host
--server-port, -p <int>      # Server bind port
--server-timeout, -t <int>   # Server timeout in seconds
```

#### Database Flags
```
--db-host <string>           # Database host
--db-port <int>              # Database port
--db-username, -u <string>   # Database username
--db-password <string>       # Database password (avoid using; prefer env vars)
--db-name, -d <string>       # Database name
```

#### Logging Flags
```
--log-level, -l <level>      # Logging level
--log-format, -f <format>    # Logging format (json|text)
```

## Configuration Validation

The service should not be considered to be ready until configuration is merged and validation is performed. 

An error in the configuration should stop the service.

This document does not define how validation is performed for services.

### Validation Error Handling
When validation fails:
1. Display **full field path** (e.g., `Config.Server.Port` not just `Port`)
2. Show **validation rule** that failed (e.g., `required`, `min`, `max`)
3. Provide **actual value** that failed validation
4. Include **helpful hints** for how to fix (flags, env vars, config file)
5. **Exit with code 1** to prevent startup with invalid configuration

Example error output:
```
Configuration validation failed:
  - Field 'Config.App.Name' failed validation: required
    Please provide application name via:
      • Flag: --app-name or -n
      • Environment variable: HYPERFLEET_APP_NAME
      • Config file: app.name
  - Field 'Config.Server.Port' failed validation: max
    Value 70000 exceeds maximum allowed value of 65535
```

### Unknown Field Handling

Any unexpected property in a config file should trigger an error either when loading the file or validating the configuration. Silently accepting unexpected properties can lead to undesired behaviour, which is usually the case with misspelled config properties.

If using `viper` for unmarshaling an struct, there is the `viper.unmarshalExact()` function that will provoke an error for unexpected values.


## Applications with multiple commands

Some applications define multiple commands (e.g. hyperfleet-api has serve and migrate commands). Configuration options should be different for each command, so it is not required to provide all configs for commands that only need a subset or completely different set of configuration options.

Configuration property names should be the same for commands that share concerns. E.g. for hyperfleet-api, all the config settings for database connection should have the same names.

## Configuration Reloading

### Standard Behavior
**HyperFleet applications do NOT support runtime configuration reloading.**

Rationale:
- **Simplicity**: Restart-based config changes are easier to reason about and test
- **Consistency**: Ensures entire config is validated together at startup
- **Safety**: Prevents partial config updates that could leave app in invalid state

### Configuration Changes
To apply configuration changes:
1. Update the configuration file or environment variables
2. Restart the application/service
3. New configuration is loaded and validated at startup

## Implementation example

An example to implement the configuration with support of cobra, viper and the [validation library](https://github.com/go-playground/validator) can be found at https://github.com/rh-amarin/viper-cobra-validation-poc. It showcases:

- Using flags for command parameters
- Configuring a file for loading configuration
- Setting prefix for environment variables
- Declarative validation of structs


## Displaying configuration

To make it easier to know the state in which the application runs, the merged configuration should be easily obtained.
- Logging the configuration at start time
- Offering a method to query it, e.g. through a `/config` endpoint that displays the values in JSON format

When displaying the configuration values, any sensitive data like credentials should be redacted and displayed as `**REDACTED**`, indicating that the value is set but can not be consulted

## Action items and next steps

This section outlines the tasks to create to implement the results of the spike in our system

### Change Sentinel to use new configuration standard
- Modify the sentinel service code to adopt the standard
- Modify existing config properties to follow the naming rules
- Modify helm files to simplify the use of environment variables if config is cover by other methods 

### Change Adapt API to use new configuration standard
- Modify the hyperfleet-api service code to adopt the standard
- Modify existing config properties to follow the naming rules
- This is a major change since it we inherit from TRex how configuration works and has to be redone
- Modify helm files to simplify the use of environment variables if config is cover by other methods 

### Change Adapter to use new configuration standard
- Modify the adaper service code to adopt the standard
- Modify existing config properties to follow the naming rules
- Leave AdapterConfig files to keep using environment variables as it is doing now for some config settings

### Change Adapter to add a new `config` source to parameter loading
- Today the AdapterConfig can read params using ` source: env.VARIABLE`
- Change it so the Adapter config can use` source: config.VARIABLE`
- That `config` object will resolve to the application config loaded as defined by the standard

### Modify the claude plugin
- Modify the plugin to take into account the new configuration standard


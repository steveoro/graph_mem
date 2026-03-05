# Development Guide

This guide covers everything you need to know to set up a development environment and contribute to the GraphMem project.

## Local Development Setup

### Prerequisites

Before starting, ensure you have the following installed:

* Ruby 3.4.1+ (we recommend using [RVM](https://rvm.io/) or [rbenv](https://github.com/rbenv/rbenv) for Ruby version management)
* MariaDB 10.5+
* [Bundler](https://bundler.io/)
* Git

### Step 1: Clone the Repository

```bash
git clone https://github.com/your-org/graph_mem.git
cd graph_mem
```

### Step 2: Install Dependencies

Install the required Ruby gems:

```bash
bundle install
```

### Step 3: Configure the Database

Copy the sample database configuration:

```bash
cp config/database.yml.sample config/database.yml
```

Edit `config/database.yml` to match your local MariaDB configuration.

### Step 4: Set Up the Database

Create and initialize the database:

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed  # Optional: loads sample data
```

### Step 5: Run the Server

Start the Rails server:

```bash
bin/rails server
```

Alternatively, use the provided MCP server script:

```bash
bin/mcp
```

For the STDIO interface (useful for Windsurf integration):

```bash
bin/windsurf_mcp_graph_mem_runner.sh
```

## Project Structure

The GraphMem project follows a standard Rails application structure with a few additions:

```
.
├── app/
│   ├── controllers/      # API controllers
│   ├── models/           # ActiveRecord models
│   ├── resources/        # MCP resources
│   ├── serializers/      # JSON serializers
│   └── tools/            # MCP tools
├── bin/                  # Scripts and utilities
├── config/
│   ├── initializers/
│   │   ├── fast_mcp.rb   # MCP server configuration
│   │   └── zzz_fast_mcp_patches.rb  # Monkey patches
│   └── ...
├── db/
│   ├── migrate/          # Database migrations
│   └── schema.rb         # Current schema definition
├── docs/                 # Documentation files
├── lib/
│   └── graph_mem/        # Core library code
└── spec/                 # Tests
```


## Code Style Guidelines

GraphMem follows the [Ruby Style Guide](https://github.com/rubocop/ruby-style-guide) with a few customizations. We use RuboCop to enforce these guidelines.

### Key Style Points

* Use 2 spaces for indentation (not tabs)
* Use snake_case for methods and variables
* Use CamelCase for classes and modules
* Keep lines under 100 characters
* Write descriptive method and variable names
* Include documentation for public methods

To check your code against our style guidelines:

```bash
bundle exec rubocop
```

To automatically fix issues:

```bash
bundle exec rubocop -a
```


## Running Tests

GraphMem uses RSpec for testing. To run all tests:

```bash
bundle exec rspec
```


## Pull Request Workflow

1. **Fork the Repository**: Create your own fork of the project

2. **Create a Feature Branch**:

```bash
git checkout -b feature/my-new-feature
```

3. **Make Your Changes**: Implement your feature or bug fix

4. **Write Tests**: Add tests for your changes

5. **Check Style**:

```bash
bundle exec rubocop
```

6. **Run Tests**:

```bash
bundle exec rspec
```

7. **Commit Your Changes**:

```bash
git commit -am "Add new feature: description"
```

8. **Push to Your Fork**:

```bash
git push origin feature/my-new-feature
```

9. **Create a Pull Request**: Through the GitHub interface

## Code Review Process

1. All code changes must be submitted via pull requests
2. At least one core maintainer must review and approve changes
3. All tests must pass
4. Code must comply with style guidelines
5. Documentation must be updated to reflect changes


## Versioning

GraphMem follows [Semantic Versioning](https://semver.org/):

* **MAJOR** version for incompatible API changes
* **MINOR** version for new functionality in a backwards compatible manner
* **PATCH** version for backwards compatible bug fixes

The current version is stored in `lib/graph_mem/version.rb`.

## Additional Resources

* [Ruby on Rails Guides](https://guides.rubyonrails.org/)
* [Fast-MCP Documentation](https://github.com/yjacquin/fast-mcp)
* [MCP Specification](https://github.com/mcporg/mcp)


## Getting Help

If you encounter issues or have questions:

1. Check the documentation in the `/docs` directory
2. Look for existing issues in the issue tracker
3. Create a new issue with:
   * A clear title and description
   * Steps to reproduce the issue
   * Expected and actual behavior
   * Any error messages or logs
   * Your environment details (Ruby version, Rails version, etc.)


## License

By contributing to GraphMem, you agree that your contributions will be licensed under the project's [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).
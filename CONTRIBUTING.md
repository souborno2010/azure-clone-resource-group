# Contributing to Azure Clone Resource Group

Thank you for your interest in contributing to the Azure Clone Resource Group project! This document provides guidelines and information about contributing to this project.

## Getting Started

### Prerequisites

- Azure CLI installed and configured
- PowerShell 5.1 or PowerShell Core 6.0+
- Appropriate Azure permissions to manage resource groups and their resources

### Setting Up the Development Environment

1. Fork the repository
2. Clone your fork locally:
   ```powershell
   git clone https://github.com/YOUR-USERNAME/azure-clone-resource-group.git
   cd azure-clone-resource-group
   ```
3. Create a new branch for your feature or bug fix:
   ```powershell
   git checkout -b feature/your-feature-name
   ```

## How to Contribute

### Reporting Bugs

- Use the [GitHub Issues](https://github.com/bradmca/azure-clone-resource-group/issues) page to report bugs
- Provide a clear and descriptive title
- Include detailed steps to reproduce the issue
- Include any error messages or screenshots
- Specify your environment (OS, PowerShell version, Azure CLI version)

### Suggesting Enhancements

- Use GitHub Issues to suggest enhancements
- Provide a clear description of the enhancement
- Explain why this enhancement would be useful
- Consider including implementation suggestions if you have ideas

### Submitting Changes

1. Ensure your code follows the existing style and conventions
2. Test your changes thoroughly
3. Update documentation if necessary
4. Commit your changes with a clear commit message:
   ```
   type(scope): brief description
   
   Detailed explanation if needed
   ```
5. Push your changes to your fork:
   ```powershell
   git push origin feature/your-feature-name
   ```
6. Create a pull request

## Code Style Guidelines

- Use PowerShell best practices
- Follow existing code formatting
- Use meaningful variable and function names
- Add comments where the code is not self-explanatory
- Include error handling where appropriate

## Testing

- Test your changes in a non-production Azure environment
- Verify that the script works with different resource types
- Test edge cases and error scenarios
- Ensure backward compatibility when making changes

## Documentation

- Update README.md if you add new features
- Update inline comments for complex code changes
- Add examples for new functionality
- Keep documentation in sync with code changes

## Pull Request Process

1. Ensure your PR description clearly describes the problem and solution
2. Link any relevant issues in your PR description
3. Include screenshots if your changes affect the user interface
4. Wait for code review feedback
5. Make requested changes if needed
6. Ensure CI checks pass

## Community

- Be respectful and constructive in all interactions
- Help others in the community
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md)

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

## Questions?

If you have questions about contributing, feel free to:
- Open an issue on GitHub
- Start a discussion in the repository

Thank you for contributing!

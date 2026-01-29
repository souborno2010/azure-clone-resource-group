# Security Policy

## Supported Versions

| Version | Supported          |
|---------|-------------------|
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it to us privately before disclosing it publicly.

### How to Report

- Email us at: [security@example.com](mailto:security@example.com)
- Include "Security Vulnerability" in the subject line
- Provide as much detail as possible about the vulnerability

### What to Include

- Type of vulnerability (e.g., XSS, SQL injection, etc.)
- Steps to reproduce the issue
- Potential impact of the vulnerability
- Any screenshots or proof-of-concept code (if available)

### Response Time

We will acknowledge receipt of your vulnerability report within 48 hours and provide a detailed response within 7 days.

### Security Best Practices for Users

- Never share your Azure credentials or service principal details
- Use least-privilege access when running the script
- Review the script before executing it in production environments
- Keep your Azure CLI and PowerShell modules up to date
- Use Azure Key Store for managing secrets instead of hardcoding them

### Security Features

This script includes several security measures:

- No hardcoded credentials
- Support for Azure AD authentication
- Validation of input parameters
- Secure handling of resource configurations

## Security Updates

Security updates will be announced through:
- GitHub releases
- Security advisories
- Commit messages tagged with `security`

## Disclaimer

This tool is provided as-is, and users are responsible for:
- Securing their Azure environment
- Following Azure security best practices
- Reviewing and understanding the script before execution
- Implementing additional security measures as needed

For more information about Azure security best practices, visit:
[Azure Security Documentation](https://docs.microsoft.com/en-us/azure/security/)

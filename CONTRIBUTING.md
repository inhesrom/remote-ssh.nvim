# Contributing to remote-ssh.nvim

Thank you for your interest in contributing! We use a standard fork-based workflow to keep the repository clean and organized.

## Fork and Pull Request Workflow

1. **Fork the repository** on GitHub
2. **Clone your fork**:
   ```bash
   git clone https://github.com/YOUR-USERNAME/remote-ssh.nvim.git
   cd remote-ssh.nvim
   ```
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** following the existing code style
5. **Test your changes**:
   ```bash
   lua tests/run_all_tests.lua
   ```
6. **Commit and push**:
   ```bash
   git commit -m "feat: describe your changes"
   git push origin feature/your-feature-name
   ```
7. **Open a Pull Request** on GitHub

## Guidelines

- **One feature per PR** - Keep pull requests focused
- **Add tests** for new functionality
- **Follow existing code style** - 4 spaces, snake_case, descriptive names
- **Update documentation** if needed
- **All tests must pass** before submitting

## Why Use Forks?

Fork-based contributions are standard practice in open source because they:
- Keep the main repository clean
- Enable proper code review through pull requests
- Allow multiple contributors to work simultaneously without conflicts
- Provide security by requiring maintainer approval for all changes

## Getting Help

- Check existing issues before creating new ones
- Create an issue to discuss major changes before implementing
- Review the README and code comments for guidance

Thank you for contributing!
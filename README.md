# SDK Deduplicator

A standalone command-line tool to deduplicate assemblies (.dll and .exe files) in a .NET SDK installation by replacing duplicates with hard links or symbolic links.

## Features

- Scans an SDK directory for duplicate assemblies
- Groups duplicates by content hash (using XxHash64)
- Replaces duplicates with hard links (Windows) or symbolic links (Linux/macOS)
- Reports space savings
- Verbose mode to see detailed deduplication progress

## Building

### Local Build

```bash
cd /repos/sdkDedup
dotnet build -c Release
```

### Docker Build

Build for Windows Server 2022:
```bash
docker build -f Dockerfile.ltsc2022 -t sdkdedup:ltsc2022 .
```

Build for Windows Server 2025:
```bash
docker build -f Dockerfile.ltsc2025 -t sdkdedup:ltsc2025 .
```

## Usage

```bash
sdkDedup <directory> [options]
```

### Arguments

- `<directory>` - Path to SDK installation directory to deduplicate

### Options

- `--hard-links, -h` - Use hard links instead of symbolic links
- `--verbose, -v` - Enable verbose output showing each file being deduplicated

## Examples

### Deduplicate a Windows SDK installation with hard links

```bash
sdkDedup "C:\Program Files\dotnet" --hard-links
```

### Deduplicate a Linux SDK installation with symbolic links (default)

```bash
sdkDedup /usr/share/dotnet
```

### Verbose mode to see all operations

```bash
sdkDedup /usr/share/dotnet --verbose
```

### Using PowerShell Script (Copy + Deduplicate + Package)

The `Deduplicate-And-Package.ps1` script automates the full workflow:

```powershell
.\Deduplicate-And-Package.ps1 -SourceSdkPath "C:\Program Files\dotnet" -OutputPath "C:\output" -UseHardLinks
```

This will:
1. Copy the entire dotnet installation to a temporary directory
2. Run deduplication on the sdk folder within the copy
3. Create a tarball of the entire dotnet installation (with deduplicated sdk)
4. Clean up the temporary directory

### Using Docker (Windows containers)

**Run the full workflow (copy + deduplicate + package):**

Windows Server 2022:
```bash
docker run --rm -v C:\output:C:\output sdkdedup:ltsc2022 pwsh C:\app\Deduplicate-And-Package.ps1 -SourceSdkPath "C:\Program Files\dotnet" -OutputPath C:\output -UseHardLinks
```

Windows Server 2025:
```bash
docker run --rm -v C:\output:C:\output sdkdedup:ltsc2025 pwsh C:\app\Deduplicate-And-Package.ps1 -SourceSdkPath "C:\Program Files\dotnet" -OutputPath C:\output -UseHardLinks
```

**Or run the deduplication tool directly:**

```bash
docker run --rm -v C:\dotnet:C:\sdk sdkdedup:ltsc2022 dotnet C:\app\bin\Release\net10.0\sdkDedup.dll C:\sdk --hard-links
```

Note: When using Docker on Windows, you need to mount directories as volumes.

## How It Works

1. **Scan**: Recursively scans the specified directory for all .dll and .exe files
2. **Hash**: Computes a content hash (XxHash64) for each assembly
3. **Group**: Groups files with identical content hashes
4. **Select Master**: For each group, selects a "master" file (closest to root, alphabetically first)
5. **Deduplicate**: Replaces all duplicates with links to the master file

## Link Types

### Hard Links (--hard-links)

- Multiple directory entries point to the same inode
- Files appear as regular files
- Requires files to be on the same filesystem
- **Windows**: Requires no special privileges
- **Linux**: Works on most filesystems

### Symbolic Links (default)

- Creates a special file that references another file
- Uses relative paths so it works when the directory is moved or archived
- **Windows**: May require Developer Mode or administrator privileges
- **Linux**: Always supported

## Output

```
Scanning for duplicate assemblies in '/usr/share/dotnet' (using symbolic links)...
Found 4962 assemblies eligible for deduplication.
Found 652 groups of duplicate assemblies.
Deduplication complete: 780 files replaced with symbolic links, saving 234.56 MB.
```

## PowerShell Script

The `Deduplicate-And-Package.ps1` script provides an end-to-end workflow for creating deduplicated SDK tarballs.

### Parameters

- **`-SourceSdkPath`** (required) - Path to the source dotnet installation root
- **`-OutputPath`** (required) - Directory where the tarball will be created
- **`-UseHardLinks`** (switch) - Use hard links instead of symbolic links
- **`-VerboseOutput`** (switch) - Enable verbose deduplication output

### Workflow

1. Creates a temporary working directory
2. Copies the entire dotnet installation to the working directory
3. Measures the sdk folder size before deduplication
4. Runs the deduplication tool on the sdk folder only
5. Measures the sdk folder size after deduplication and reports savings
6. Creates a compressed tarball of the entire dotnet installation using `tar -czf`
7. Verifies the tarball contents
8. Cleans up the temporary directory

### Output

The script creates a tarball named `dotnet-deduplicated-{timestamp}.tar.gz` in the specified output directory.

## Based On

This tool is based on the `DeduplicateAssembliesWithLinks` MSBuild task from the .NET SDK build infrastructure.

## License

Licensed to the .NET Foundation under the MIT license.

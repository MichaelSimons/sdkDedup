// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Hashing;
using System.Linq;
using System.Runtime.InteropServices;

namespace SdkDedup
{
    class Program
    {
        static int Main(string[] args)
        {
            var config = ParseArguments(args);
            if (config == null)
            {
                PrintUsage();
                return 1;
            }

            var deduplicator = new AssemblyDeduplicator(config.LayoutDirectory, config.UseHardLinks, config.Verbose);
            bool success = deduplicator.Execute();
            return success ? 0 : 1;
        }

        static DeduplicationConfig? ParseArguments(string[] args)
        {
            if (args.Length == 0)
            {
                return null;
            }

            var config = new DeduplicationConfig
            {
                LayoutDirectory = args[0],
                UseHardLinks = args.Contains("--hard-links") || args.Contains("-h"),
                Verbose = args.Contains("--verbose") || args.Contains("-v")
            };

            return config;
        }

        static void PrintUsage()
        {
            Console.WriteLine("SDK Deduplicator - Deduplicate assemblies in an SDK installation");
            Console.WriteLine();
            Console.WriteLine("Usage: sdkDedup <directory> [options]");
            Console.WriteLine();
            Console.WriteLine("Arguments:");
            Console.WriteLine("  <directory>      Path to SDK installation directory to deduplicate");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --hard-links, -h Use hard links instead of symbolic links");
            Console.WriteLine("  --verbose, -v    Enable verbose output");
            Console.WriteLine();
            Console.WriteLine("Examples:");
            Console.WriteLine("  sdkDedup C:\\Program Files\\dotnet --hard-links");
            Console.WriteLine("  sdkDedup /usr/share/dotnet");
        }

        class DeduplicationConfig
        {
            public string LayoutDirectory { get; set; } = null!;
            public bool UseHardLinks { get; set; }
            public bool Verbose { get; set; }
        }
    }

    public class AssemblyDeduplicator
    {
        private readonly string _layoutDirectory;
        private readonly bool _useHardLinks;
        private readonly bool _verbose;

        private string LinkType => _useHardLinks ? "hard link" : "symbolic link";

        public AssemblyDeduplicator(string layoutDirectory, bool useHardLinks, bool verbose)
        {
            _layoutDirectory = layoutDirectory;
            _useHardLinks = useHardLinks;
            _verbose = verbose;
        }

        public bool Execute()
        {
            if (!Directory.Exists(_layoutDirectory))
            {
                Console.Error.WriteLine($"Error: Directory '{_layoutDirectory}' does not exist.");
                return false;
            }

            Console.WriteLine($"Scanning for duplicate assemblies in '{_layoutDirectory}' (using {LinkType}s)...");

            // Find all eligible files - only assemblies
            var files = Directory.GetFiles(_layoutDirectory, "*", SearchOption.AllDirectories)
                .Where(f => IsAssembly(f))
                .ToList();

            Console.WriteLine($"Found {files.Count} assemblies eligible for deduplication.");

            var (filesByHash, hashingSuccess) = HashAndGroupFiles(files);
            if (!hashingSuccess)
            {
                return false;
            }

            var duplicateGroups = filesByHash.Values.Where(g => g.Count > 1).ToList();
            Console.WriteLine($"Found {duplicateGroups.Count} groups of duplicate assemblies.");

            bool success = DeduplicateFileGroups(duplicateGroups);

            return success;
        }

        private (Dictionary<string, List<FileEntry>> filesByHash, bool success) HashAndGroupFiles(List<string> files)
        {
            var filesByHash = new Dictionary<string, List<FileEntry>>();
            bool hasErrors = false;

            foreach (var filePath in files)
            {
                try
                {
                    var fileInfo = new FileInfo(filePath);
                    var hash = ComputeFileHash(filePath);
                    var entry = new FileEntry(
                        filePath,
                        hash,
                        fileInfo.Length,
                        GetPathDepth(filePath, _layoutDirectory));

                    if (!filesByHash.ContainsKey(hash))
                    {
                        filesByHash[hash] = new List<FileEntry>();
                    }

                    filesByHash[hash].Add(entry);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"Error: Failed to hash file '{filePath}': {ex.Message}");
                    hasErrors = true;
                }
            }

            return (filesByHash, !hasErrors);
        }

        private bool DeduplicateFileGroups(List<List<FileEntry>> duplicateGroups)
        {
            int totalFilesDeduped = 0;
            long totalBytesSaved = 0;
            bool hasErrors = false;

            foreach (var group in duplicateGroups)
            {
                // Sort deterministically: by depth (ascending), then alphabetically
                var sorted = group.OrderBy(f => f.Depth).ThenBy(f => f.Path).ToList();

                // First file is the "master"
                var master = sorted[0];
                var duplicates = sorted.Skip(1).ToList();

                if (_verbose)
                {
                    Console.WriteLine($"Group: {Path.GetFileName(master.Path)} ({group.Count} files, {master.Size:N0} bytes)");
                    Console.WriteLine($"  Master: {master.Path}");
                }

                foreach (var duplicate in duplicates)
                {
                    try
                    {
                        CreateLink(duplicate.Path, master.Path);
                        totalFilesDeduped++;
                        totalBytesSaved += duplicate.Size;
                        if (_verbose)
                        {
                            Console.WriteLine($"  Linked: {duplicate.Path} -> {master.Path}");
                        }
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"Error: Failed to create {LinkType} from '{duplicate.Path}' to '{master.Path}': {ex.Message}");
                        hasErrors = true;
                    }
                }
            }

            Console.WriteLine($"Deduplication complete: {totalFilesDeduped} files replaced with {LinkType}s, saving {totalBytesSaved / (1024.0 * 1024.0):F2} MB.");

            return !hasErrors;
        }

        private void CreateLink(string duplicateFilePath, string masterFilePath)
        {
            // Delete the duplicate file first
            File.Delete(duplicateFilePath);

            if (_useHardLinks)
            {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                {
                    CreateHardLinkWindows(duplicateFilePath, masterFilePath);
                }
                else
                {
                    CreateHardLinkUnix(duplicateFilePath, masterFilePath);
                }
            }
            else
            {
                // Create relative symlink so it works when directory is moved/archived
                var duplicateDirectory = Path.GetDirectoryName(duplicateFilePath)!;
                var relativePath = Path.GetRelativePath(duplicateDirectory, masterFilePath);
                File.CreateSymbolicLink(duplicateFilePath, relativePath);
            }
        }

        private static string ComputeFileHash(string filePath)
        {
            byte[] fileBytes = File.ReadAllBytes(filePath);
            var hashBytes = XxHash64.Hash(fileBytes);
            return BitConverter.ToString(hashBytes).Replace("-", "").ToLowerInvariant();
        }

        private static int GetPathDepth(string filePath, string rootDirectory)
        {
            var relativePath = Path.GetRelativePath(rootDirectory, filePath);
            return relativePath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Length - 1;
        }

        private static bool IsAssembly(string filePath)
        {
            var extension = Path.GetExtension(filePath);
            return extension.Equals(".dll", StringComparison.OrdinalIgnoreCase) ||
                   extension.Equals(".exe", StringComparison.OrdinalIgnoreCase);
        }

        private void CreateHardLinkWindows(string linkPath, string targetPath)
        {
            bool result = CreateHardLinkWin32(linkPath, targetPath, IntPtr.Zero);
            if (!result)
            {
                int errorCode = Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"CreateHardLink failed with error code {errorCode}");
            }
        }

        private void CreateHardLinkUnix(string linkPath, string targetPath)
        {
            int result = link(targetPath, linkPath);
            if (result != 0)
            {
                int errorCode = Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"link() failed with error code {errorCode}");
            }
        }

        [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateHardLinkWin32(
            string lpFileName,
            string lpExistingFileName,
            IntPtr lpSecurityAttributes);

        [DllImport("libc", SetLastError = true)]
        private static extern int link(string oldpath, string newpath);

        private record FileEntry(string Path, string Hash, long Size, int Depth);
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.Common
{
    public static class NextendoSplatoon3Bcat
    {
        public const string TitleId = "0100c2500fc20000";
        private static readonly string[] Regions = { "ap-default", "eu-default", "jp-default", "us-default" };
        private static readonly string[] RequiredFiles = { "summary.yml", "base.pack.zs.enc", "bh.pack.zs.enc", "wa.pack.zs.enc", "wb.pack.zs.enc", "wc.pack.zs.enc" };
        private static readonly SemaphoreSlim SyncLock = new(1, 1);
        private const int MaximumSize = 32 * 1024 * 1024;

        public static bool IsInstalled(string target) => Regions.All(region => RequiredFiles.All(file =>
            File.Exists(Path.Combine(target, region, file)) && new FileInfo(Path.Combine(target, region, file)).Length > 0));

        public static async Task<bool> SyncAsync(HttpClient http, string baseUrl, string seedRoot, bool force = false)
        {
            using CancellationTokenSource deadline = new(TimeSpan.FromSeconds(60));
            CancellationToken token = deadline.Token;
            await SyncLock.WaitAsync(token);
            try
            {
                string target = Path.Combine(seedRoot, TitleId);
                if (!IsInstalled(target) && IsInstalled(seedRoot))
                {
                    using MemoryStream legacy = new();
                    using (ZipArchive package = new(legacy, ZipArchiveMode.Create, leaveOpen: true))
                    {
                        foreach (string region in Regions)
                        foreach (string path in Directory.EnumerateFiles(Path.Combine(seedRoot, region)))
                        {
                            package.CreateEntryFromFile(path, region + "/" + Path.GetFileName(path));
                        }
                    }
                    Install(legacy.ToArray(), target);
                }
                using HttpResponseMessage response = await http.GetAsync(
                    $"{baseUrl.TrimEnd('/')}/api/bcat/{TitleId}", HttpCompletionOption.ResponseHeadersRead, token);
                if (response.StatusCode is HttpStatusCode.NoContent or HttpStatusCode.NotFound)
                {
                    throw new InvalidDataException("No Splatoon 3 BCAT package is published on the server.");
                }
                response.EnsureSuccessStatusCode();
                if (response.Content.Headers.ContentLength > MaximumSize)
                {
                    throw new InvalidDataException("BCAT download exceeds 32 MiB.");
                }
                using Stream remote = await response.Content.ReadAsStreamAsync(token);
                using MemoryStream bytes = new();
                byte[] buffer = new byte[65536];
                int read;
                while ((read = await remote.ReadAsync(buffer.AsMemory(), token)) != 0)
                {
                    if (bytes.Length + read > MaximumSize) throw new InvalidDataException("BCAT download exceeds 32 MiB.");
                    bytes.Write(buffer, 0, read);
                }
                return Install(bytes.ToArray(), Path.Combine(seedRoot, TitleId), force);
            }
            finally { SyncLock.Release(); }
        }

        public static bool Install(byte[] zip, string target, bool force = false)
        {
            using MemoryStream bytes = new(zip);
            using ZipArchive archive = new(bytes, ZipArchiveMode.Read);
            if (archive.Entries.Count > 512) throw new InvalidDataException("Too many BCAT entries.");
            HashSet<string> names = new(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                string name = entry.FullName;
                string[] parts = name.TrimEnd('/').Split('/');
                bool isDir = name.EndsWith('/');
                if ((isDir ? parts.Length != 1 : parts.Length != 2) ||
                    !Regions.Contains(parts[0], StringComparer.Ordinal) ||
                    parts.Any(p => p.Length == 0 || p.Length > 31 || p == "." || p == ".." ||
                        p.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '_' && c != '-' && c != '.')) ||
                    !names.Add(name.TrimEnd('/')) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                {
                    throw new InvalidDataException("Invalid Splatoon 3 BCAT path; publish regional folders at the ZIP root.");
                }
                total += entry.Length;
                if (total > MaximumSize) throw new InvalidDataException("Expanded BCAT exceeds 32 MiB.");
            }
            foreach (string region in Regions)
            foreach (string file in RequiredFiles)
            {
                if (archive.GetEntry(region + "/" + file)?.Length is not > 0)
                    throw new InvalidDataException($"BCAT package is missing {region}/{file}.");
            }

            target = Path.GetFullPath(target);
            bool matches = !force && Directory.Exists(target) &&
                Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories).Count() == archive.Entries.Count(e => !e.FullName.EndsWith('/'));
            foreach (ZipArchiveEntry entry in archive.Entries.Where(e => !e.FullName.EndsWith('/')))
            {
                string localPath = Path.Combine(target, entry.FullName);
                if (!matches || !File.Exists(localPath) || new FileInfo(localPath).Length != entry.Length)
                {
                    matches = false;
                    break;
                }
                using Stream incoming = entry.Open();
                using Stream local = File.OpenRead(localPath);
                if (!SHA256.HashData(incoming).AsSpan().SequenceEqual(SHA256.HashData(local)))
                {
                    matches = false;
                    break;
                }
            }
            if (matches) return false;

            Directory.CreateDirectory(Path.GetDirectoryName(target));
            string stage = target + ".stage-" + Guid.NewGuid().ToString("N");
            string backup = target + ".backup-" + Guid.NewGuid().ToString("N");
            bool moved = false;
            try
            {
                Directory.CreateDirectory(stage);
                archive.ExtractToDirectory(stage);
                if (!IsInstalled(stage)) throw new InvalidDataException("Incomplete BCAT extraction.");
                if (Directory.Exists(target))
                {
                    Directory.Move(target, backup);
                    moved = true;
                }
                try { Directory.Move(stage, target); }
                catch
                {
                    if (moved) Directory.Move(backup, target);
                    throw;
                }
                if (moved) Directory.Delete(backup, recursive: true);
                return true;
            }
            finally
            {
                if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true);
            }
        }
    }
}

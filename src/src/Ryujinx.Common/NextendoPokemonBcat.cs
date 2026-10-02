using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;

namespace Ryujinx.Common
{
    public static class NextendoPokemonBcat
    {
        public static void Install(byte[] zip, string target)
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
                    parts.Any(p => p.Length == 0 || p.Length > 31 || p == "." || p == ".." ||
                        p.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '_' && c != '-' && c != '.')) ||
                    !names.Add(name) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                    throw new InvalidDataException("Invalid Pokémon BCAT path.");
                total += entry.Length;
                if (total > 32 * 1024 * 1024) throw new InvalidDataException("Expanded BCAT exceeds 32 MiB.");
            }
            if (total == 0) throw new InvalidDataException("Empty BCAT package.");
            target = Path.GetFullPath(target);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            string stage = target + ".stage-" + Guid.NewGuid().ToString("N");
            string backup = target + ".backup-" + Guid.NewGuid().ToString("N");
            bool moved = false;
            try
            {
                Directory.CreateDirectory(stage);
                archive.ExtractToDirectory(stage);
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
            }
            finally
            {
                if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true);
            }
        }
    }
}

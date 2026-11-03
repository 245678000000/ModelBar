using System.Security.AccessControl;
using System.Security.Principal;

namespace ModelBar.Core;

public static class FileSupport
{
    /// <summary>原子写入并保留已有文件的权限。工具正占用文件时会稍等重试。</summary>
    public static void WriteAtomically(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(temp, data);
        Retry(() =>
        {
            if (File.Exists(path))
            {
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temp, File.GetUnixFileMode(path));
                // Replace 会保留目标文件的 ACL，Move 不会。
                File.Replace(temp, path, null);
            }
            else
            {
                File.Move(temp, path);
            }
        }, () => File.Delete(temp));
    }

    /// <summary>只有当前用户能读。Windows 上关闭权限继承，只留当前用户和系统账户。</summary>
    public static void WritePrivate(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        RestrictDirectory(directory);
        var temp = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(temp, data);
        RestrictFile(temp);
        Retry(() => File.Move(temp, path, overwrite: true), () => File.Delete(temp));
    }

    public static void RestrictFile(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            var security = new FileSecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            foreach (var identity in PrivateIdentities())
                security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl, AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(security);
        }
        else
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    private static void RestrictDirectory(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            foreach (var identity in PrivateIdentities())
            {
                security.AddAccessRule(new FileSystemAccessRule(
                    identity,
                    FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None,
                    AccessControlType.Allow));
            }
            new DirectoryInfo(path).SetAccessControl(security);
        }
        else
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static IEnumerable<IdentityReference> PrivateIdentities()
    {
        yield return WindowsIdentity.GetCurrent().User!;
        yield return new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
    }

    private static void Retry(Action action, Action cleanup)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception error) when (attempt < 4 && error is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100 * (attempt + 1));
            }
            catch
            {
                try { cleanup(); } catch (IOException) { }
                throw;
            }
        }
    }
}

/// <summary>改动工具配置前保留副本，每个标签最多保留 limit 份。</summary>
public sealed class BackupStore(string directory, int limit = 10)
{
    public string Directory => directory;

    public string? Backup(string file, string label, DateTimeOffset? now = null)
    {
        if (!File.Exists(file)) return null;
        var stamp = (now ?? DateTimeOffset.Now).ToString("yyyyMMdd-HHmmss-fff");
        var target = Path.Combine(directory, $"{label}-{stamp}-{Path.GetFileName(file)}");
        FileSupport.WritePrivate(target, File.ReadAllBytes(file));
        foreach (var old in Backups(label).SkipLast(limit)) File.Delete(old);
        return target;
    }

    public IReadOnlyList<string> Backups(string label)
    {
        if (!System.IO.Directory.Exists(directory)) return [];
        return System.IO.Directory.GetFiles(directory, label + "-*").Order(StringComparer.Ordinal).ToList();
    }
}

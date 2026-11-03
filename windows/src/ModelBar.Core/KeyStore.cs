using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace ModelBar.Core;

public interface IKeyStore
{
    string? GetKey(Guid id);
    void SetKey(Guid id, string? key);
}

/// <summary>主密钥存放在 Windows 凭据管理器。</summary>
[SupportedOSPlatform("windows")]
public sealed partial class CredentialManagerStore(string prefix = "ModelBar") : IKeyStore
{
    private const uint GenericCredential = 1;
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    private string Target(Guid id) => $"{prefix}/{id:D}";

    public string? GetKey(Guid id)
    {
        if (!CredRead(Target(id), GenericCredential, 0, out var handle))
        {
            var error = Marshal.GetLastPInvokeError();
            if (error == ErrorNotFound) return null;
            throw new ConfigException($"无法读取凭据管理器：错误 {error}");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(handle);
            if (credential.CredentialBlobSize == 0) return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(handle);
        }
    }

    public void SetKey(Guid id, string? key)
    {
        if (string.IsNullOrEmpty(key))
        {
            if (!CredDelete(Target(id), GenericCredential, 0))
            {
                var error = Marshal.GetLastPInvokeError();
                if (error != ErrorNotFound) throw new ConfigException($"无法修改凭据管理器：错误 {error}");
            }
            return;
        }
        var bytes = Encoding.UTF8.GetBytes(key);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        var target = Marshal.StringToCoTaskMemUni(Target(id));
        var user = Marshal.StringToCoTaskMemUni("ModelBar");
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = GenericCredential,
                TargetName = target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = PersistLocalMachine,
                UserName = user,
            };
            if (!CredWrite(ref credential, 0))
                throw new ConfigException($"无法写入凭据管理器：错误 {Marshal.GetLastPInvokeError()}");
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
            Marshal.FreeCoTaskMem(target);
            Marshal.FreeCoTaskMem(user);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);
}

/// <summary>只用于测试。</summary>
public sealed class InMemoryKeyStore : IKeyStore
{
    private readonly Dictionary<Guid, string> _values = [];

    public string? GetKey(Guid id)
    {
        lock (_values) return _values.GetValueOrDefault(id);
    }

    public void SetKey(Guid id, string? key)
    {
        lock (_values)
        {
            if (string.IsNullOrEmpty(key)) _values.Remove(id);
            else _values[id] = key;
        }
    }
}

/// <summary>隔离运行时使用的文件版本，不碰真实凭据。</summary>
public sealed class SandboxFileKeyStore(string directory) : IKeyStore
{
    private string FileFor(Guid id) => Path.Combine(directory, $"{id:D}.master");

    public string? GetKey(Guid id) => File.Exists(FileFor(id)) ? File.ReadAllText(FileFor(id)) : null;

    public void SetKey(Guid id, string? key)
    {
        if (string.IsNullOrEmpty(key)) File.Delete(FileFor(id));
        else FileSupport.WritePrivate(FileFor(id), Encoding.UTF8.GetBytes(key));
    }
}

public sealed class ConfigException(string message) : Exception(message);

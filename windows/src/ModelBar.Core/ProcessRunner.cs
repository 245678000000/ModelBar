using System.Diagnostics;
using System.Text;

namespace ModelBar.Core;

public static class ProcessRunner
{
    public readonly record struct Result(int ExitCode, string Output);

    /// <summary>进程退出后立刻返回，不等输出关闭：被拉起的后台进程会继承输出端。</summary>
    public static Result Run(string executable, IEnumerable<string> arguments, TimeSpan timeout, IReadOnlyDictionary<string, string>? environment = null)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        if (environment is not null)
        {
            foreach (var (name, value) in environment) start.Environment[name] = value;
        }

        var output = new StringBuilder();
        try
        {
            using var process = Process.Start(start)!;
            process.OutputDataReceived += (_, e) => { if (e.Data is not null) lock (output) output.AppendLine(e.Data); };
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (output) output.AppendLine(e.Data); };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.StandardInput.Close();
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return new Result(-2, "执行超时");
            }
            lock (output) return new Result(process.ExitCode, output.ToString());
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return new Result(-1, error.Message);
        }
    }
}

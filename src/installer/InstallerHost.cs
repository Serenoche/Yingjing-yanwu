using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
internal static class InstallerHost {
    private const string ShortExtraction =
        "解压路径过长。请把 ZIP 重新完整解压到磁盘根目录下的短文件夹，例如 D:\\演武，再打开安装器。";
    private const string MissingPackage =
        "安装器文件不完整。请重新下载 Windows 安装包，完整解压 ZIP 后运行「影境演武安装器.exe」。";

    [STAThread] private static int Main(string[] args) {
        try {
            string root=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string script=Path.Combine(root,"Open-PbzInstaller.ps1");
            if (!File.Exists(script)) {
                script=Path.Combine(root,"IntegratedMenu","Open-PbzInstaller.ps1");
                if (script.Length>=260) return ShowFailure(ShortExtraction);
            }
            if (!File.Exists(script)) return ShowFailure(MissingPackage);
            string mode=(Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location).Contains("卸载")
                || (args.Length==1 && args[0]=="--uninstall"))?"Uninstall":"Install";
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe");
            ProcessStartInfo start=new ProcessStartInfo(ps,"-NoProfile -STA -ExecutionPolicy Bypass -File \""+script+"\" -Mode "+mode);
            start.UseShellExecute=false;start.CreateNoWindow=true;start.WindowStyle=ProcessWindowStyle.Hidden;
            start.WorkingDirectory=Path.GetDirectoryName(script);
            using (Process process=Process.Start(start)) { if (process==null) throw new IOException("Could not start the installer."); }
            return 0;
        } catch (PathTooLongException) {
            return ShowFailure(ShortExtraction);
        } catch (Exception) {
            return ShowFailure("Windows 无法启动安装器。请完整解压安装包，核对 Windows PowerShell 可用，再重新打开。");
        }
    }

    private static int ShowFailure(string message) {
        MessageBox.Show(message,"影境演武",MessageBoxButtons.OK,MessageBoxIcon.Error);
        return 1;
    }
}

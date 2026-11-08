using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
internal static class InstallerHost {
    [STAThread] private static int Main(string[] args) {
        try {
            string root=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string script=Path.Combine(root,"Open-PbzInstaller.ps1");
            if (!File.Exists(script)) script=Path.Combine(root,"IntegratedMenu","Open-PbzInstaller.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Keep this program with the complete IntegratedMenu folder.");
            string mode=(Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location).Contains("卸载")
                || (args.Length==1 && args[0]=="--uninstall"))?"Uninstall":"Install";
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe");
            ProcessStartInfo start=new ProcessStartInfo(ps,"-NoProfile -STA -ExecutionPolicy Bypass -File \""+script+"\" -Mode "+mode);
            start.UseShellExecute=false;start.CreateNoWindow=true;start.WindowStyle=ProcessWindowStyle.Hidden;
            start.WorkingDirectory=Path.GetDirectoryName(script);
            using (Process process=Process.Start(start)) { if (process==null) throw new IOException("Could not start the installer."); }
            return 0;
        } catch (Exception error) { MessageBox.Show(error.Message,"影境演武",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1; }
    }
}

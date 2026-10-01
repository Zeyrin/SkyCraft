// « Installer SkyCraft.exe » : l'installateur en un seul fichier, et le lanceur du raccourci.
//
// Installer SkyCraft.exe          dépose SkyCraft-Installer.ps1 et SkyCraft-<version>.zip (ses
//                                  ressources) dans %LOCALAPPDATA%\SkyCraft\installer, s'y copie, et
//                                  lance l'assistant (PowerShell, sans fenêtre console).
// SkyCraft.exe --play              (le raccourci du Bureau) vérifie que SKSE et Address Library
//                                  suivent la version de Skyrim, puis lance skse64_loader.exe. Sinon
//                                  (Steam a mis Skyrim à jour), il l'explique et rouvre l'assistant.
//
// Compilé par tools\package.ps1 avec le csc de .NET Framework 4 présent sur tout Windows (C# 5).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Installer SkyCraft")]
[assembly: AssemblyProduct("SkyCraft")]

static class Program
{
	static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SkyCraft");
	static readonly string InstallerDir = Path.Combine(Root, "installer");

	[STAThread]
	static int Main(string[] args)
	{
		try {
			if (Array.IndexOf(args, "--play") >= 0 && Play()) {
				return 0;
			}
			RunInstaller();
			return 0;
		} catch (Exception e) {
			MessageBox.Show("SkyCraft n'a pas pu démarrer :\n\n" + e.Message, "SkyCraft", MessageBoxButtons.OK, MessageBoxIcon.Error);
			return 1;
		}
	}

	// true : le jeu est lancé, ou le joueur ne veut pas de l'assistant. false : ouvrir l'assistant.
	static bool Play()
	{
		string gameFile = Path.Combine(Root, "game.txt");
		if (!File.Exists(gameFile)) {
			return false;
		}
		string game = File.ReadAllText(gameFile).Trim();
		string skyrim = Path.Combine(game, "SkyrimSE.exe");
		string loader = Path.Combine(game, "skse64_loader.exe");
		if (!File.Exists(skyrim)) {
			return false;
		}
		FileVersionInfo v = FileVersionInfo.GetVersionInfo(skyrim);
		string version = v.FileMajorPart + "." + v.FileMinorPart + "." + v.FileBuildPart;
		string tag = v.FileMajorPart + "_" + v.FileMinorPart + "_" + v.FileBuildPart;
		bool skse = File.Exists(loader) && File.Exists(Path.Combine(game, "skse64_" + tag + ".dll"));
		bool addressLibrary = File.Exists(Path.Combine(game, @"Data\SKSE\Plugins\versionlib-" + tag.Replace('_', '-') + "-0.bin"));
		if (skse && addressLibrary) {
			ProcessStartInfo start = new ProcessStartInfo(loader);
			start.WorkingDirectory = game;
			start.UseShellExecute = true;
			Process.Start(start);
			return true;
		}
		string missing = skse ? "Address Library" : (addressLibrary ? "SKSE" : "SKSE et Address Library");
		DialogResult answer = MessageBox.Show(
			"Steam a mis Skyrim à jour (version " + version + "), et " + missing + " doit suivre cette version.\n\n" +
			"L'installateur va t'aider à télécharger la bonne version (2 minutes).\n" +
			"Si Nexus ne l'a pas encore, la mise à jour sort en général en quelques jours : réessaie plus tard.\n\n" +
			"Ouvrir l'installateur ?",
			"SkyCraft", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
		return answer != DialogResult.Yes;
	}

	static void RunInstaller()
	{
		Directory.CreateDirectory(InstallerDir);
		Assembly self = Assembly.GetExecutingAssembly();

		// Une copie de soi qui reste en place pour le raccourci, même si l'exe téléchargé est supprimé.
		string launcher = Path.Combine(InstallerDir, "SkyCraft.exe");
		if (!string.Equals(Path.GetFullPath(self.Location), Path.GetFullPath(launcher), StringComparison.OrdinalIgnoreCase)) {
			File.Copy(self.Location, launcher, true);
		}

		// Les ressources : le script de l'assistant et le zip de SkyCraft (on retire les anciens zips).
		foreach (string old in Directory.GetFiles(InstallerDir, "SkyCraft-*.zip")) {
			bool current = false;
			foreach (string name in self.GetManifestResourceNames()) {
				if (string.Equals(Path.GetFileName(old), name, StringComparison.OrdinalIgnoreCase)) {
					current = true;
				}
			}
			if (!current) {
				File.Delete(old);
			}
		}
		foreach (string name in self.GetManifestResourceNames()) {
			string path = Path.Combine(InstallerDir, name);
			using (Stream resource = self.GetManifestResourceStream(name)) {
				if (File.Exists(path) && new FileInfo(path).Length == resource.Length && !name.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) {
					continue;
				}
				using (FileStream file = File.Create(path)) {
					resource.CopyTo(file);
				}
			}
		}

		string script = Path.Combine(InstallerDir, "SkyCraft-Installer.ps1");
		if (!File.Exists(script)) {
			throw new FileNotFoundException("SkyCraft-Installer.ps1 manque dans l'installateur.");
		}
		ProcessStartInfo ps = new ProcessStartInfo("powershell.exe",
			"-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -Launcher \"" + launcher + "\"");
		ps.UseShellExecute = false;
		ps.CreateNoWindow = true;
		ps.WorkingDirectory = InstallerDir;
		Process.Start(ps);
	}
}

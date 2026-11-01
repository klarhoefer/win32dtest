# win32dtest

Einfache Win32-GUI-Anwendung in D (nur `core.sys.windows`, keine externen Bibliotheken).

- **Fenster** mit einer Liste (ListView) aller Dateien und Verzeichnisse im
  TMP-Verzeichnis (`GetTempPathW`), die zuletzt **vor der letzten Mitternacht**
  (00:00 Uhr heute, lokale Zeit) geändert wurden – Spalten: Name, Typ, Datum, Größe.
- **Suche** (Strg+F): filtert die Liste beim Tippen nach Namen
  (Teilstring, Groß-/Kleinschreibung egal).
- **Alle markieren** (Button oder Strg+A): markiert alle angezeigten Einträge.
  Einzelne Einträge lassen sich wie gewohnt mit Strg/Umschalt + Klick markieren.
- **In den Papierkorb** (Button, Entf oder Menü): verschiebt die markierten Einträge
  per `SHFileOperationW` mit `FOF_ALLOWUNDO` in den Papierkorb; Windows fragt vorher nach.
- Eine Info-Zeile zeigt angezeigte/gesamte/markierte Einträge, das TMP-Verzeichnis und den Stichtag.
- **Menü**: *Datei → Suchen / Aktualisieren (F5) / Beenden*,
  *Bearbeiten → Alle markieren / In den Papierkorb*, *Hilfe → Über…*

## Bauen und Starten (Windows)

Voraussetzung: DMD oder LDC sowie dub.

```bash
dub run
```

Mit LDC:

```bash
dub run --compiler=ldc2
```

Die Linker-Flags `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup` sorgen dafür, dass kein
Konsolenfenster geöffnet wird, obwohl das normale D-`main` verwendet wird.

Für das moderne Aussehen (visuelle Stile, Common Controls 6.0) setzt der Quelltext per
`pragma(linkerDirective, "/manifestdependency:...")` eine Manifest-Abhängigkeit;
`/MANIFEST:EMBED` bettet das Manifest direkt in die EXE ein. Das funktioniert mit dem
Microsoft-Linker (`link.exe`) und mit `lld-link`, die DMD und LDC unter Windows standardmäßig nutzen.

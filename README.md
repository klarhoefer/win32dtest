# win32dtest

Einfache Win32-GUI-Anwendung in D (nur `core.sys.windows`, keine externen Bibliotheken).

- **Fenster** mit einer Liste (ListView) aller Dateien und Verzeichnisse im
  TMP-Verzeichnis (`GetTempPathW`), die zuletzt **vor der letzten Mitternacht**
  (00:00 Uhr heute, lokale Zeit) geändert wurden – Spalten: Name, Typ, Datum, Größe.
  Darüber eine Info-Zeile mit Begrüßung und Anzahl der Einträge.
- **Menü**: *Datei → Name eingeben… (Strg+N) / Aktualisieren (F5) / Beenden*, *Hilfe → Über…*
- **Dialog**: modaler Dialog mit Textfeld, OK und Abbrechen. Das Dialog-Template
  wird zur Laufzeit im Speicher erzeugt (`DialogBoxIndirectParamW`), daher wird
  kein Ressourcen-Compiler benötigt.

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

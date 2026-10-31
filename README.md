# SV-Planer
Lokale Web-App zur Planung von SV-/Schülerrat-Sitzungen (Tagesordnung, Protokoll, Anwesenheit, Anträge, Jahresplan …).
Alle Daten bleiben im Browser (localStorage), Sicherung per JSON-Export/-Import unter „Daten“. Kein Backend, keine Cloud.

Installierbar als App (PWA): im Browser „Installieren“ / „Zur Startseite hinzufügen“.

## Online-Abstimmung (optional)
Für Umfragen mit Link und QR-Code: einmal `sv-abstimmung.sql` im Supabase-Dashboard unter „SQL Editor“ ausführen. Danach im Reiter „Umfragen“ bei einer Umfrage „Online freischalten“ wählen. Die Seite `abstimmen.html` ist die Abstimmungsseite für Teilnehmende. Ergebnisse sieht nur, wer im Planer angemeldet ist.

## Öffentliche SV-Seite (optional)
Eine Seite mit Terminen, Beschlüssen und Projekten für alle Schüler/innen: einmal `sv-seite.sql` im Supabase-Dashboard unter „SQL Editor“ ausführen. Danach im Planer unter „Vorlagen“ den Reiter „Öffentliche Seite“ öffnen, auswählen was erscheinen soll und auf „Veröffentlichen“ klicken. Die Seite ist `sv.html`. Es wird nur veröffentlicht, was du auswählst, und nur auf Knopfdruck.

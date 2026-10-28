# The fonts the Linux app ships

Both are free to bundle with an app, commercial use included. The same two files are in
`docs/assets/fonts/` for the guide.

- **Luckiest Guy** (`LuckiestGuy-Regular.ttf`), by Astigmatic. Apache License 2.0.
  https://fonts.google.com/specimen/Luckiest+Guy
- **Inter** (`Inter-Variable.ttf`), by Rasmus Andersson. SIL Open Font License 1.1.
  https://rsms.me/inter/

They are added to fontconfig when the app starts (`wellspent_fonts_add_file`), so the
style sheet can name them. Nothing is installed on the computer.

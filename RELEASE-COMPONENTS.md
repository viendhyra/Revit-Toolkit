# Release components-2026-10-05

Пакеты публикуются как вложения GitHub Releases, без добавления бинарников в исходный код.

| Package | Version | Local status | SHA256 |
|---|---|---|---|
| `AdskIdentityManager-1.12.0-Installer.exe` | 1.12.0 | Ready; valid Autodesk signature | `15ed723753078615a3b545b09f6ed39f20eefce08a66b38a4c5f7e2026c17b8b` |
| `nlm11.19.9.0_ipv4_ipv6_win64.msi` | 11.19.9.0 | Missing; Autodesk download returned HTTP 503 | `fc54f6e88f569c5c32df7e65a58a04307d39c2852465fa91cc4ce16a3ad43af7` |
| `fab.zip` | 1.9 | Ready; x64 SHA1 matches Sordum | `278baecab6ce9d729425e5cd0aec0294f2ce5803342afc8328e4c7ae69a8dbfd` |

Identity copied unmodified from the official local 3ds Max 2025.3 installation image. Package XML identifies component version 1.12.0. This is an older version, not a current update.

FAB downloaded unmodified from [Sordum](https://www.sordum.org/downloads/?firewall-app-blocker). Executable hashes are published on the [official FAB page](https://www.sordum.org/8125/firewall-app-blocker-fab-v1-9/). Customized local firewall settings and other local utilities are excluded.

Get NLM from [Autodesk's official NLM page](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/EB0JPJWkEgBXjZRPBONh1.html) and save the MSI with the exact name above in `release-assets`. The SHA256 is published by Autodesk.

## Publication

1. Place all three packages in `release-assets`.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ReleaseAssets.ps1`. All three must pass.
3. Open [New GitHub release](https://github.com/viendhyra/Revit-Toolkit/releases/new). Create tag `components-2026-10-05` on the intended code revision.
4. Attach exactly the three packages listed above. Do not upload `fab-check`, diagnostics, local configuration or licenses.
5. Publish the release, update the script and README in the repository, then remove the pending-publication status from README only after checking the three download links.

GitHub browser sign-in is currently required to upload these assets. No release has been published by this task.

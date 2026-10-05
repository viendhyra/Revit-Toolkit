# Release components-2026-10-05

Пакеты публикуются как вложения GitHub Releases, без добавления бинарников в исходный код.

| Package | Version | Local status | SHA256 |
|---|---|---|---|
| `AdskIdentityManager-1.21.0.9-UCT-Installer.exe` | 1.21.0.9 | Ready; valid Autodesk signature | `c0209ba50ca088849a6cbae5e9da33486d86b1bc6b14d228786c689ce5bdc6bd` |
| `nlm11.19.9.0_ipv4_ipv6_win64.msi` | 11.19.9.0 | Ready; valid Autodesk signature | `fc54f6e88f569c5c32df7e65a58a04307d39c2852465fa91cc4ce16a3ad43af7` |
| `fab.zip` | 1.9 | Ready; x64 SHA1 matches Sordum | `278baecab6ce9d729425e5cd0aec0294f2ce5803342afc8328e4c7ae69a8dbfd` |

Identity downloaded unmodified from https://up.autodesk.com/Windows/1.21.0.9/AdskIdentityManager-UCT-Installer.exe, linked on the official Autodesk Identity Manager support page.

FAB downloaded unmodified from [Sordum](https://www.sordum.org/downloads/?firewall-app-blocker). Executable hashes are published on the [official FAB page](https://www.sordum.org/8125/firewall-app-blocker-fab-v1-9/). Customized local firewall settings and other local utilities are excluded.

Get NLM from [Autodesk's official NLM page](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/EB0JPJWkEgBXjZRPBONh1.html) and save the MSI with the exact name above in `release-assets`. The SHA256 is published by Autodesk.

## Publication

1. Place all three packages in `release-assets`.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ReleaseAssets.ps1`. All three must pass.
3. Open [New GitHub release](https://github.com/viendhyra/Revit-Toolkit/releases/new). Create tag `components-2026-10-05` on the intended code revision.
4. Attach exactly the three packages listed above. Do not upload `fab-check`, diagnostics, local configuration or licenses.
5. Publish the release, update the script and README in the repository, then remove the pending-publication status from README only after checking the three download links.

The publish-components workflow downloads these exact vendor packages, checks SHA256 and Autodesk signatures, uploads all three to a draft release, then publishes it. Release published successfully: https://github.com/viendhyra/Revit-Toolkit/releases/tag/components-2026-10-05. All three GitHub asset digests match the pinned SHA256 values. Manual browser upload is a fallback for future releases.

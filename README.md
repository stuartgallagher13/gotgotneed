# Got Got Need

Who played for who? Every player, every club, every season, starting with England's top six tiers.

## What's here

| File | What it does |
|---|---|
| `index.html` | The web version: home, search, player profiles, club pages, every English club |
| `build_data.rb` | The nightly data copy: every club's players and season-by-season squads into `data/` |
| `.github/workflows/nightly-data.yml` | Runs the copy every night on GitHub and publishes app + data on GitHub Pages |

## Where the data comes from

- **Wikidata** (CC0, free for any use): which players played for which club, with dates, appearances and goals.
- **Wikipedia** (CC BY-SA, credit required): current squad lists, and past seasons' squads from the page history.
- **Wikimedia Commons**: player photos, credited to the photographer on each profile. Photos are linked, not copied.
- Club crests are trademarked, so the app draws its own initial badges instead.

## Hosting

GitHub Pages serves the app and data for free:

- App: `https://<github-username>.github.io/<repo>/`
- Data for the mobile app: `https://<github-username>.github.io/<repo>/data/clubs.json` and `data/teams/<Wikidata id>.json`

### One-time setup

1. Create a **public** GitHub repository (Pages is free for public repos) and push this folder to it.
2. Settings > Secrets and variables > Actions > **New repository secret**: name `WIKIMEDIA_CONTACT`, value your contact email.
   Wikimedia asks automated tools to identify themselves; anonymous ones get rate-limited.
3. Settings > Pages > Build and deployment > Source: **GitHub Actions**.
4. Actions > **Nightly data copy** > Run workflow. The first run copies everything (30–60 minutes); later nights only fetch what changed.

Note: GitHub pauses scheduled workflows in a repo with no commits for 60 days. It emails a warning first, and one click re-enables it.

## Running locally

```bash
CONTACT=you@example.com ruby build_data.rb --only Q19612   # just Preston
ruby -run -e httpd . -p 8765                              # then open http://localhost:8765
```

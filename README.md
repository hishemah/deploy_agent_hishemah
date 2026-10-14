# deploy_agent

A bash script that sets up, runs and archives logs for the attendance tracker app. The original source files are in `templates/` and I didn't change them.

Video: https://youtu.be/M59PDsW1Onk

## Running it

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh
```

This opens a menu: 1 = deploy, 2 = run, 3 = archive logs, 4 = exit.
You can also skip the menu with `./deploy_agent.sh deploy`, `./deploy_agent.sh run v1` or `./deploy_agent.sh archive v1`.

## Deploy

1. Checks that `python3` and `zip` are installed.
2. Asks for a name and creates `attendance_tracker_<name>/` with `Helpers/` and `reports/`. If the folder already exists, it asks before overwriting.
3. Copies the app and `config.json` from `templates/`, then builds `assets.csv` one of two ways:
   - **A:** copies the first N students from the template, which already has 4 sessions recorded, so `total_sessions` stays 5.
   - **B:** generates N new students with 0/0 counts, so `total_sessions` is set to 1.
4. Makes the app executable and sets `config.json` to `chmod 600`.
5. Asks if you want to change the thresholds, then runs the app to prove the setup works.

**Thresholds:** if you say yes, you enter new warning and failure values (just press Enter to keep 75 and 50). `sed` then replaces only the number after `"warning":` and `"failure":` in the deployed `config.json`. Nothing else in the file changes.

## Archive

Moves each log into its own folder with a timestamp in the name:

```
archives/attendance/attendance_20260927_143022.log
archives/absent/absent_20260927_143022.log
```

If a log doesn't exist (for example, nobody was absent), the script says so and skips it.

## Ctrl+C / Ctrl+Z

To test: start a deploy, enter a name, and press Ctrl+C (or Ctrl+Z) at the "Choose A or B" prompt.
The script says the deployment was interrupted, zips what was created so far into `attendance_tracker_<name>_archive.zip`, and deletes the unfinished folder.
At that point the zip contains `attendance_checker.py`, `Helpers/config.json` and an empty `reports/`. If you interrupt later (at the threshold question), `assets.csv` is in there too.
You can check the contents with `unzip -l attendance_tracker_<name>_archive.zip`.

The trap is turned off before the app starts, so Ctrl+C while marking only stops the Python app.

## Testing

I deployed with both roster options and checked the result with `find attendance_tracker_v1 | sort`, `ls -l` and `cat` on the config and roster. I then ran marking sessions and confirmed the counts and logs updated.
I also tested interrupting at different prompts, overwriting an existing folder, invalid input and archiving when `absent.log` was missing.

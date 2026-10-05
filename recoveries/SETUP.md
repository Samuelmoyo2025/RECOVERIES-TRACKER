# Recoveries Tracker: setup guide

The project has three files:

| File | What it is |
|---|---|
| `index.html` | The whole web app. It runs in **demo mode** (data saved in the browser only) until you paste in your Supabase keys. |
| `supabase/schema.sql` | Database tables, security rules, POP file storage, audit trail and the reminder digest. |
| `SETUP.md` | This guide. |

---

## 1. Try it first (demo mode, 2 minutes)

Open `index.html` in Chrome or Edge. Pick a person (for example *Samuel Moyo – Admin*), then go to **Upload claims → Upload from Excel** and drop in the current `Recoveries_UPDATED` workbook. Tick **Migration mode** and upload.

To see each seat, sign out and sign back in as someone else:
- **M. Makumbe**, a credit controller: sees only his reminders and can record recoveries with a POP.
- **Finance Officer**: verifies POPs.
- **Claims Officer**: uploads claims.

---

## 2. Create the database (Supabase, about 10 minutes)

1. Go to https://supabase.com, create a project (region: *eu-west* or *af-south* if offered) and set a strong DB password.
2. Open **SQL Editor → New query**, paste all of `supabase/schema.sql` and click **Run**. Running it again later is safe.
3. Open **Authentication → URL Configuration** and set **Site URL** to the Vercel address from step 3 (you can come back to this once you have it).
4. Optional: under **Authentication → Providers → Email**, restrict sign-ups to `@zimnat.co.zw` addresses, or turn off "Allow new users to sign up" once everyone has an account.
5. Open **Project Settings → API** and copy the **Project URL** and the **anon public** key.

Open `index.html` and fill in the CONFIG block at the top of the script:

```js
const CONFIG = {
  SUPABASE_URL: 'https://xxxxxxxx.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOi...',
  COMPANY: 'Zimnat General Insurance'
};
```

The anon key is meant to be public. The row-level security in `schema.sql` decides what each person can see and change.

---

## 3. Publish on Vercel

Add the folder to your **ZGI-ToolKit** repo (for example `recoveries/index.html`) and push. Vercel redeploys on its own. The tool is then at `https://<your-vercel-domain>/recoveries/`.

---

## 4. First sign-in and roles

1. **You sign up first.** The first account created automatically becomes **Admin**.
2. Ask each colleague to open the link and choose **Create an account**. New accounts start as *Viewer* (read-only).
3. Go to **Settings → Users & roles** and set:
   - **Role**: Claims, Finance, Credit control, Admin or Viewer.
   - **"Responsible" name** for each credit controller. It must match the name used on recoveries exactly, e.g. `M. Makumbe`. This links their reminders and their dashboard line.
4. Go to **Upload claims → Upload from Excel**, upload the current workbook and tick **Migration mode** (admin only). This brings in:
   - every USD and ZWG line,
   - "Recovered To Date" as an opening receipt marked *Migrated* (already verified),
   - comments as activity history,
   - lines already 100% recovered, which go straight to the archive.
5. In **Settings → Reinsurers**, tidy up names. Use **Merge duplicates** for spelling variants and set each reinsurer's **default controller**, so new uploads assign themselves.

### Who can do what

| | Claims | Finance | Credit control | Admin | Viewer |
|---|:-:|:-:|:-:|:-:|:-:|
| Upload or edit claims | ✓ | ✓ | | ✓ | |
| Log follow-ups / promises | ✓ | ✓ | ✓ | ✓ | |
| Record recovery + POP | | ✓ | ✓ | ✓ | |
| Verify / reject POPs | | ✓ | | ✓ | |
| Write off a balance | | ✓ | | ✓ | |
| Users, reinsurers, rules, migration | | | | ✓ | |

The database enforces these rules, not just the screens. For example, a credit controller cannot change a claim amount even by calling the API directly. Receipts and POPs can't be deleted, and recoveries are never deleted by users.

---

## 5. Daily email reminders (Power Automate)

The database builds each controller's list for you. Power Automate only has to fetch it and send the emails from the shared mailbox you already use for the Treasury Report.

**Get the token** (Supabase → SQL Editor):
```sql
select token from public.digest_config;
```

**Build the flow:** *Scheduled cloud flow*, named "Recoveries – daily reminders".

1. **Recurrence**: every 1 day at 07:30, time zone *(UTC+02:00) Harare, Pretoria*. Under *On these days*, choose Mon–Fri.
2. **HTTP** action:
   - Method: `POST`
   - URI: `https://xxxxxxxx.supabase.co/rest/v1/rpc/reminder_digest`
   - Headers:
     - `apikey`: *your anon key*
     - `Authorization`: `Bearer` *your anon key*
     - `Content-Type`: `application/json`
   - Body: `{"p_token": "<token from above>"}`
3. **Parse JSON**: Content = *Body* of the HTTP step. Schema:
   ```json
   {"type":"array","items":{"type":"object","properties":{
     "email":{"type":"string"},"name":{"type":"string"},"count":{"type":"integer"},
     "urgent":{"type":"integer"},"subject":{"type":"string"},"html":{"type":"string"}}}}
   ```
4. **Apply to each**: *Body* of Parse JSON.
5. Inside the loop, **Send an email from a shared mailbox (V2)**:
   - Original Mailbox Address: your shared mailbox
   - To: `email`
   - Subject: `subject`
   - Body: switch to code view `</>` and paste:
     ```html
     <p>Good morning @{items('Apply_to_each')?['name']},</p>
     <p>These recoveries need follow-up today:</p>
     @{items('Apply_to_each')?['html']}
     <p><a href="https://<your-vercel-domain>/recoveries/">Open the Recoveries Tracker</a> to log a follow-up or record a recovery with its POP.</p>
     ```
   - Importance: High

**How the reminders work.** A recovery keeps appearing in the email every morning until someone acts on it, in this order of priority:

| Reason | When it fires |
|---|---|
| Unassigned | No credit controller set. This goes to Admin and Finance. |
| Promise missed | A reinsurer promised to pay by a date that has passed, and nothing has been received since. |
| Follow-up due | The controller's own "next follow-up" date has arrived. |
| New, not yet actioned | Claims or finance uploaded it and nobody has touched it yet. |
| No follow-up logged | Nothing logged for 7 days. You can change this in Settings → Reminder rules. |

The in-app **Reminders** page and the red badge use the same rules, so the email and the screen always agree.

> The HTTP action is a Power Automate **premium** connector. If your licence doesn't include it, ask IT for a premium licence for the flow owner. The fallback is a Supabase Edge Function on a schedule (pg_cron) that sends the email through Microsoft Graph or SMTP. The `reminder_digest()` function already produces the subject and HTML, so the sender only has to deliver them.

---

## 6. Day to day

- **Claims / Finance → Upload claims.** Enter one claim payment with one line per reinsurer and its share %. Or upload the Excel template.
- **Credit control → Reminders.** Log a follow-up (call, email, meeting or *payment promise* with a date), or **Record recovery + POP**.
- **When a claim reaches 100% recovered**, it leaves the register and moves to **Recovered archive** with all its receipts and POPs. Nothing is deleted.
- **Finance → POP verification.** Check each POP against the bank statement and verify or reject it. Rejecting reverses the amount and brings the claim back to the register.
- **Statements & exports.** Download a statement of what one reinsurer owes, to send with follow-ups, or full Excel exports.
- **Audit trail.** Every change shows who made it and when.

## Backups

Supabase Pro takes daily backups. On the free tier, download **Statements & exports → All USD / All ZWG** weekly. POP files are in Supabase **Storage → pops**.

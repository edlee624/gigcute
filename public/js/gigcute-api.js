// ============================================================================
// GigCute API layer — thin wrapper over Supabase.
//
// Loaded as an ES module. Reads config from window.GIGCUTE_CONFIG (set in
// config.js, which is gitignored — copy config.example.js and fill in your
// project URL + anon key). Exposes window.GigCuteAPI for the app's inline
// script to call.
//
// The anon key is safe to ship to the browser: it is gated by the Row Level
// Security policies in supabase/migrations. Never put the service_role key here.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cfg = window.GIGCUTE_CONFIG || {};
const enabled = Boolean(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY);

const supabase = enabled
  ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY)
  : null;

function requireClient() {
  if (!supabase) {
    throw new Error('GigCute backend not configured. Copy config.example.js to config.js and add your Supabase URL + anon key.');
  }
  return supabase;
}

// ---- Auth -----------------------------------------------------------------
const auth = {
  // role: 'seeker' | 'recruiter'. full_name flows into the profiles row via the
  // handle_new_user trigger.
  async signUp({ email, password, role, fullName }) {
    const { data, error } = await requireClient().auth.signUp({
      email, password,
      options: { data: { role, full_name: fullName || '' } },
    });
    if (error) throw error;
    return data;
  },
  async signIn({ email, password }) {
    const { data, error } = await requireClient().auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },
  async signInWithGoogle() {
    const { data, error } = await requireClient().auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin },
    });
    if (error) throw error;
    return data;
  },
  async signOut() {
    const { error } = await requireClient().auth.signOut();
    if (error) throw error;
  },
  async sendPasswordReset(email) {
    const { error } = await requireClient().auth.resetPasswordForEmail(email, {
      redirectTo: window.location.origin,
    });
    if (error) throw error;
  },
  async currentUser() {
    if (!supabase) return null;
    const { data } = await supabase.auth.getUser();
    return data?.user ?? null;
  },
  onChange(cb) {
    if (!supabase) return () => {};
    const { data } = supabase.auth.onAuthStateChange((_e, session) => cb(session));
    return () => data.subscription.unsubscribe();
  },
};

// ---- Profiles -------------------------------------------------------------
const profiles = {
  async me() {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    if (!u?.user) return null;
    const { data, error } = await c.from('profiles').select('*').eq('id', u.user.id).single();
    if (error) throw error;
    return data;
  },
  async update(patch) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { data, error } = await c.from('profiles').update(patch).eq('id', u.user.id).select().single();
    if (error) throw error;
    return data;
  },
};

// ---- Storage --------------------------------------------------------------
// Public 'media' bucket (see migration 0003). Returns a public URL.
async function uploadPublic(path, file) {
  const c = requireClient();
  const { error } = await c.storage.from('media').upload(path, file, { upsert: true, cacheControl: '3600' });
  if (error) throw error;
  return c.storage.from('media').getPublicUrl(path).data.publicUrl;
}
function safeName(name) { return (name || 'file').replace(/[^a-zA-Z0-9._-]/g, '_'); }

// ---- Seeker profile -------------------------------------------------------
const seeker = {
  async upsert(profile) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const row = { ...profile, profile_id: u.user.id };
    const { data, error } = await c.from('seeker_profiles').upsert(row).select().single();
    if (error) throw error;
    return data;
  },

  // Upload a profile photo for the current user; returns the public URL.
  async uploadPhoto(file) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    return uploadPublic(`avatars/${u.user.id}/${Date.now()}_${safeName(file.name)}`, file);
  },

  // Persist the full seeker profile: the main row plus work history, education,
  // and prompt answers. Child collections are replaced wholesale (fine for the
  // small sizes here). Pass already-uploaded photo_url in `profile`.
  async saveFull({ profile = {}, workHistory = [], education = [], promptAnswers = [] }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const uid = u.user.id;

    let { error } = await c.from('seeker_profiles').upsert({ ...profile, profile_id: uid });
    if (error) throw error;

    await c.from('work_history').delete().eq('seeker_id', uid);
    if (workHistory.length) {
      ({ error } = await c.from('work_history').insert(workHistory.map((w, i) => ({
        seeker_id: uid, title: w.title || null, company: w.company || null,
        start_label: w.start || null, end_label: w.end || null,
        description: w.description || null, sort_order: i,
      }))));
      if (error) throw error;
    }

    await c.from('education').delete().eq('seeker_id', uid);
    if (education.length) {
      ({ error } = await c.from('education').insert(education.map((e, i) => ({
        seeker_id: uid, degree: e.degree || null, school: e.school || null, year: e.year || null, sort_order: i,
      }))));
      if (error) throw error;
    }

    await c.from('seeker_prompt_answers').delete().eq('seeker_id', uid);
    if (promptAnswers.length) {
      ({ error } = await c.from('seeker_prompt_answers').insert(promptAnswers.map((p, i) => ({
        seeker_id: uid, prompt_label: p.label, answer: p.answer || null,
        is_favorite: !!p.isFavorite, sort_order: i,
      }))));
      if (error) throw error;
    }
    return true;
  },

  async get(seekerId) {
    const { data, error } = await requireClient()
      .from('seeker_profiles')
      .select('*, work_history(*), education(*), seeker_prompt_answers(*)')
      .eq('profile_id', seekerId).single();
    if (error) throw error;
    return data;
  },
  async setLinkedinUrl(url) {
    return seeker.upsert({ linkedin_url: url });
  },
};

// ---- Companies ------------------------------------------------------------
const companies = {
  async create(company) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { data, error } = await c.from('companies')
      .insert({ ...company, owner_id: u.user.id }).select().single();
    if (error) throw error;
    return data;
  },
  async update(id, patch) {
    const { data, error } = await requireClient().from('companies').update(patch).eq('id', id).select().single();
    if (error) throw error;
    return data;
  },
  async mine() {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { data, error } = await c.from('companies').select('*').eq('owner_id', u.user.id);
    if (error) throw error;
    return data;
  },
  // Upload a company logo; returns the public URL. Call before create/update and
  // pass the result as logo_url.
  async uploadLogo(file) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    return uploadPublic(`logos/${u.user.id}/${Date.now()}_${safeName(file.name)}`, file);
  },
  // Verification status of the current recruiter's company.
  async myStatus() {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    if (!u?.user) return null;
    const { data, error } = await c.from('companies')
      .select('id, name, verified, email_domain').eq('owner_id', u.user.id).limit(1);
    if (error) throw error;
    return data && data[0] ? data[0] : null;
  },
};

// ---- Admin ----------------------------------------------------------------
const admin = {
  // Manually verify/unverify a company (server checks the caller is an admin).
  async setCompanyVerified(companyId, verified) {
    const { error } = await requireClient().rpc('admin_set_company_verified', {
      p_company: companyId, p_verified: verified,
    });
    if (error) throw error;
  },
};

// Free / disposable email providers — client-side hint only (the database is the
// real enforcement). Keep roughly in sync with blocked_email_domains.
const FREE_EMAIL_DOMAINS = new Set([
  'gmail.com','googlemail.com','yahoo.com','ymail.com','outlook.com','hotmail.com','live.com','msn.com',
  'icloud.com','me.com','mac.com','aol.com','gmx.com','gmx.net','mail.com','proton.me','protonmail.com',
  'pm.me','yandex.com','yandex.ru','zoho.com','fastmail.com','hey.com','tutanota.com','hotmail.co.uk',
  'yahoo.co.uk','comcast.net','verizon.net','mailinator.com','tempmail.com','temp-mail.org','guerrillamail.com',
  '10minutemail.com','throwaway.email','trashmail.com','getnada.com','dispostable.com','yopmail.com',
  'sharklasers.com','tempmail.io','maildrop.cc','mintemail.com','fakeinbox.com','emailondeck.com',
]);
function isFreeEmailDomain(email) {
  const d = String(email || '').toLowerCase().split('@')[1];
  return !!d && FREE_EMAIL_DOMAINS.has(d);
}

// ---- Postings -------------------------------------------------------------
const postings = {
  async listActive() {
    const { data, error } = await requireClient()
      .from('postings')
      .select('*, companies(name, logo_url, linkedin_url)')
      .eq('status', 'active')
      .order('published_at', { ascending: false });
    if (error) throw error;
    return data;
  },
  async forCompany(companyId) {
    const { data, error } = await requireClient().from('postings').select('*').eq('company_id', companyId);
    if (error) throw error;
    return data;
  },
  async create(posting) {
    const { data, error } = await requireClient().from('postings').insert(posting).select().single();
    if (error) throw error;
    return data;
  },
  async update(id, patch) {
    const { data, error } = await requireClient().from('postings').update(patch).eq('id', id).select().single();
    if (error) throw error;
    return data;
  },
  async addScreeningQuestion(q) {
    // The DB trigger enforces tier limits and forces voluntary questions to be non-essential.
    const { data, error } = await requireClient().from('screening_questions').insert(q).select().single();
    if (error) throw error;
    return data;
  },
};

// ---- Interest / invites / matches -----------------------------------------
const interest = {
  async seekerLike(postingId) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { error } = await c.from('seeker_interest').upsert({ seeker_id: u.user.id, posting_id: postingId });
    if (error) throw error;
  },
  async recruiterLike(postingId, seekerId) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { error } = await c.from('recruiter_interest')
      .upsert({ posting_id: postingId, seeker_id: seekerId, created_by: u.user.id });
    if (error) throw error;
  },
  async myMatches() {
    const { data, error } = await requireClient().from('matches').select('*');
    if (error) throw error;
    return data;
  },
};

const invites = {
  async send({ postingId, seekerId, type = 'regular', note = '' }) {
    const { data, error } = await requireClient().from('invites')
      .upsert({ posting_id: postingId, seeker_id: seekerId, type, note, status: 'pending' })
      .select().single();
    if (error) throw error;
    return data;
  },
  async respond(inviteId, status) { // 'accepted' | 'declined'
    const { data, error } = await requireClient().from('invites')
      .update({ status, responded_at: new Date().toISOString() }).eq('id', inviteId).select().single();
    if (error) throw error;
    return data;
  },
  async inbox() {
    const { data, error } = await requireClient().from('invites')
      .select('*, postings(title, companies(name))').eq('status', 'pending');
    if (error) throw error;
    return data;
  },
};

// ---- Voluntary EEO/DE&I responses (write-only from the candidate side) -----
const eeo = {
  async submit(postingId, responses /* [{category, value}] */) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const rows = responses.map(r => ({ posting_id: postingId, seeker_id: u.user.id, ...r }));
    const { error } = await c.from('eeo_responses').upsert(rows);
    if (error) throw error;
  },
  // Recruiters can only ever see suppressed aggregates, never individual rows.
  async aggregate(postingId) {
    const { data, error } = await requireClient().rpc('eeo_aggregate', { p_posting: postingId });
    if (error) throw error;
    return data;
  },
};

// ---- Reference data + misc ------------------------------------------------
const reference = {
  async promptBank() {
    const { data, error } = await requireClient().from('prompt_bank').select('*').order('id');
    if (error) throw error;
    return data;
  },
  async screeningTemplates() {
    const { data, error } = await requireClient().from('screening_templates').select('*').order('sort_order');
    if (error) throw error;
    return data;
  },
};

const reports = {
  async file({ targetType, targetId, reason, details }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { error } = await c.from('reports')
      .insert({ reporter_id: u.user?.id, target_type: targetType, target_id: String(targetId), reason, details });
    if (error) throw error;
  },
};

window.GigCuteAPI = {
  enabled,
  supabase,
  auth, profiles, seeker, companies, postings, interest, invites, eeo, reference, reports, admin,
  isFreeEmailDomain,
};

// Let the inline app know the API is ready (it may load after this module).
window.dispatchEvent(new CustomEvent('gigcute-api-ready'));

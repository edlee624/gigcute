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
// Supabase client is self-hosted (public/js/vendor/supabase.umd.js, loaded as a
// classic script before this module) and exposed as the global `supabase`.
// This avoids a runtime CDN import that slowed every cold page load.
const { createClient } = window.supabase || {};

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

// Cache the current user id so fire-and-forget event logging stays synchronous
// (no getUser() round-trip per tracked event).
let _uid = null;
if (supabase) {
  supabase.auth.getUser().then(({ data }) => { _uid = data?.user?.id || null; }).catch(() => {});
  supabase.auth.onAuthStateChange((_e, session) => { _uid = session?.user?.id || null; });
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
  // Permanently delete the current user's account (via the delete-account Edge
  // Function, which uses the service role). Cascades to profile + all child data.
  async deleteAccount() {
    const c = requireClient();
    const { data, error } = await c.functions.invoke('delete-account', { method: 'POST' });
    if (error) throw error;
    if (data && data.error) throw new Error(data.error);
    try { await c.auth.signOut(); } catch (_e) { /* session is gone anyway */ }
    return data;
  },
  async sendPasswordReset(email) {
    const { error } = await requireClient().auth.resetPasswordForEmail(email, {
      redirectTo: window.location.origin,
    });
    if (error) throw error;
  },
  // Set a new password for the currently-authenticated (or recovery) session.
  async updatePassword(password) {
    const { error } = await requireClient().auth.updateUser({ password });
    if (error) throw error;
  },
  // Fires when the user arrives via a password-recovery link. The Supabase client
  // establishes a temporary session and emits PASSWORD_RECOVERY.
  onPasswordRecovery(cb) {
    if (!supabase) return () => {};
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY') cb(session);
    });
    return () => data.subscription.unsubscribe();
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
  // Record that the current user viewed a seeker's profile. Signed-in viewers are
  // keyed by their uid; anonymous (shared-link) visitors by a stable local token,
  // so they count as distinct people. RPC still no-ops on self-views.
  async logProfileView(seekerId) {
    let vid = null;
    try {
      vid = localStorage.getItem('gc_vid');
      if (!vid) { vid = 'v_' + Math.random().toString(36).slice(2) + Date.now().toString(36); localStorage.setItem('gc_vid', vid); }
    } catch (e) { /* private mode / storage disabled */ }
    const { error } = await requireClient().rpc('log_profile_view', { p_seeker: seekerId, p_visitor: vid });
    if (error) throw error;
  },
  // Distinct people who viewed the current user's profile in the last `days` days.
  async myProfileViews(days = 7) {
    const { data, error } = await requireClient().rpc('my_profile_views', { p_days: days });
    if (error) throw error;
    return data || 0;
  },
  // Public shareable profile by id (any visible seeker) — for /profile/<id>.
  async publicProfile(id) {
    const { data, error } = await requireClient().rpc('public_profile', { p_id: id });
    if (error) throw error;
    return data; // jsonb object, or null if not found/visible
  },
  // Public shareable profile by short code — for /profile/<code> (migration 0015).
  async publicProfileByCode(code) {
    const { data, error } = await requireClient().rpc('public_profile_by_code', { p_code: code });
    if (error) throw error;
    return data; // jsonb object, or null if not found/visible
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

  // Pause / resume the profile — hides it from recruiters when is_visible=false.
  async setVisibility(visible) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { data, error } = await c.from('seeker_profiles')
      .upsert({ profile_id: u.user.id, is_visible: !!visible }).select('is_visible').single();
    if (error) throw error;
    return data;
  },

  // Upload a profile photo for the current user; returns the public URL.
  async uploadPhoto(file) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    return uploadPublic(`avatars/${u.user.id}/${Date.now()}_${safeName(file.name)}`, file);
  },

  // Upload the resume file for the current user; returns the public URL.
  async uploadResume(file) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    return uploadPublic(`resumes/${u.user.id}/${Date.now()}_${safeName(file.name)}`, file);
  },

  // Persist the full seeker profile: the main row plus work history, education,
  // and prompt answers. Child collections are replaced wholesale (fine for the
  // small sizes here). Pass already-uploaded photo_url in `profile`.
  async saveFull({ profile = {}, workHistory = [], education = [], promptAnswers = [] }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const uid = u.user.id;

    let { error } = await c.from('seeker_profiles').upsert({ ...profile, profile_id: uid });
    // Resilience: if an optional column (e.g. resume_url or portfolio, before its
    // migration is applied) isn't in the schema yet, save the rest rather than fail.
    if (error && /schema cache|could not find .* column|column .* does not exist/i.test(error.message || '')) {
      const { resume_url, portfolio, certifications, ...rest } = profile;
      ({ error } = await c.from('seeker_profiles').upsert({ ...rest, profile_id: uid }));
    }
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

// ---- ID verification (personal/flagged-email recruiters) ------------------
const verification = {
  // Upload the ID-selfie photo to the PRIVATE 'verification' bucket. Returns the
  // storage path (not a public URL — the bucket has no public read).
  async uploadId(file) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const path = `${u.user.id}/${Date.now()}_${safeName(file.name)}`;
    const { error } = await c.storage.from('verification').upload(path, file, { upsert: true });
    if (error) throw error;
    return path;
  },
  // Create a review request linked to the uploader's company (if any).
  async submit({ docPath }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    let company_id = null;
    try {
      const m = await c.from('companies').select('id').eq('owner_id', u.user.id).limit(1);
      if (m.data && m.data[0]) company_id = m.data[0].id;
    } catch (e) { /* company may not exist yet */ }
    const { error } = await c.from('verification_requests')
      .insert({ profile_id: u.user.id, company_id, doc_path: docPath });
    if (error) throw error;
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
  // Pending ID-verification requests (admin only via RLS).
  async pendingVerifications() {
    const { data, error } = await requireClient()
      .from('verification_requests')
      .select('*, profiles!verification_requests_profile_id_fkey(full_name, email), companies(name)')
      .eq('status', 'pending').order('created_at');
    if (error) throw error;
    return data;
  },
  // Approve/reject a request; approving also verifies the company.
  async reviewVerification(requestId, approve, note) {
    const { error } = await requireClient().rpc('admin_review_verification', {
      p_request: requestId, p_approve: approve, p_note: note || null,
    });
    if (error) throw error;
  },
  // Signed URL to view a private verification doc (admin).
  async verificationDocUrl(docPath, seconds = 120) {
    const { data, error } = await requireClient().storage.from('verification').createSignedUrl(docPath, seconds);
    if (error) throw error;
    return data.signedUrl;
  },

  // Support tickets queue (admin reads all via RLS). status: 'open'|'resolved'|'escalated'|null(all)
  async listSupportTickets(status = null) {
    let q = requireClient()
      .from('support_tickets')
      .select('*, profiles!support_tickets_reporter_id_fkey(full_name, email)')
      .order('created_at', { ascending: false });
    if (status) q = q.eq('status', status);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },
  // Resolve / escalate / reopen a ticket. status: 'resolved'|'escalated'|'open'
  async setSupportTicketStatus(id, status) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const patch = { status, reviewed_by: u?.user?.id || null };
    patch.resolved_at = status === 'resolved' ? new Date().toISOString() : null;
    const { error } = await c.from('support_tickets').update(patch).eq('id', id);
    if (error) throw error;
  },
  // Reported content (admin reads all via RLS).
  async listReports(status = null) {
    let q = requireClient()
      .from('reports')
      .select('*, profiles(full_name, email)')
      .order('created_at', { ascending: false });
    if (status) q = q.eq('status', status);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },
  // Resolve / escalate / reopen a report. status: 'resolved'|'escalated'|'open'
  async setReportStatus(id, status) {
    const { error } = await requireClient().from('reports').update({ status }).eq('id', id);
    if (error) throw error;
  },
  // End-of-chat feedback (admin reads all via RLS).
  async listChatFeedback() {
    const { data, error } = await requireClient()
      .from('chat_feedback')
      .select('*, profiles!chat_feedback_rater_id_fkey(full_name)')
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data;
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
  // The current recruiter's own postings (across their companies).
  async mine() {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    if (!u?.user) return [];
    const cos = await c.from('companies').select('id').eq('owner_id', u.user.id);
    if (cos.error) throw cos.error;
    const ids = (cos.data || []).map(r => r.id);
    if (!ids.length) return [];
    const { data, error } = await c.from('postings').select('*').in('company_id', ids).order('created_at', { ascending: false });
    if (error) throw error;
    return data;
  },
  async create(posting) {
    const { data, error } = await requireClient().from('postings').insert(posting).select().single();
    if (error) throw error;
    return data;
  },
  // Record that someone viewed a posting (signed-in by uid, anon by visitor token;
  // owner-views are skipped server-side). Fire-and-forget.
  async logView(postingId) {
    let vid = null;
    try { vid = localStorage.getItem('gc_vid'); if (!vid) { vid = 'v_' + Math.random().toString(36).slice(2) + Date.now().toString(36); localStorage.setItem('gc_vid', vid); } } catch (e) {}
    const { error } = await requireClient().rpc('log_posting_view', { p_posting: postingId, p_visitor: vid });
    if (error) throw error;
  },
  // Headline stats { views, views_7d, interested } for a posting the caller owns.
  async stats(postingId) {
    const { data, error } = await requireClient().rpc('posting_stats', { p_posting: postingId });
    if (error) throw error;
    return data || null;
  },
  // Aggregate professional breakdown of viewers, split by liked vs not-liked.
  async audience(postingId) {
    const { data, error } = await requireClient().rpc('posting_audience', { p_posting: postingId });
    if (error) throw error;
    return data || null;
  },
  // Potential-match candidates for a posting (visible seekers not already interested).
  async recommend(postingId, limit = 8) {
    const { data, error } = await requireClient().rpc('recommend_candidates', { p_posting: postingId, p_limit: limit });
    if (error) throw error;
    return data || [];
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
  // "We'd love to know" prompt labels attached to a posting.
  async addRequestedPrompts(postingId, labels) {
    if (!labels || !labels.length) return;
    const rows = labels.map((label, i) => ({ posting_id: postingId, prompt_label: label, sort_order: i }));
    const { error } = await requireClient().from('posting_requested_prompts').insert(rows);
    if (error) throw error;
  },
  async getRequestedPrompts(postingId) {
    const { data, error } = await requireClient()
      .from('posting_requested_prompts').select('prompt_label').eq('posting_id', postingId).order('sort_order');
    if (error) throw error;
    return (data || []).map(r => r.prompt_label);
  },
  async clearRequestedPrompts(postingId) {
    const { error } = await requireClient().from('posting_requested_prompts').delete().eq('posting_id', postingId);
    if (error) throw error;
  },
  async getScreeningQuestions(postingId) {
    const { data, error } = await requireClient()
      .from('screening_questions').select('*').eq('posting_id', postingId).order('sort_order');
    if (error) throw error;
    return data || [];
  },
  async clearScreeningQuestions(postingId) {
    const { error } = await requireClient().from('screening_questions').delete().eq('posting_id', postingId);
    if (error) throw error;
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
  // Seekers who liked a posting the caller owns. Returns SAFE fields only
  // (name, headline, photo — never email), via a security-definer RPC gated by
  // owns_posting (see migration 0010). Each row also flags whether the recruiter
  // already liked back (mutual = a match exists) and the conversation id if open.
  async seekersWhoLiked(postingId) {
    const { data, error } = await requireClient().rpc('seekers_who_liked', { p_posting: postingId });
    if (error) throw error;
    return data || [];
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

// ---- Chat / messaging ------------------------------------------------------
const chat = {
  // All conversations the current user participates in (seeker or company member).
  async listConversations() {
    const { data, error } = await requireClient()
      .from('conversations')
      .select('id, posting_id, seeker_id, last_message_at, postings(title, companies(name)), seeker_profiles(headline)')
      .order('last_message_at', { ascending: false });
    if (error) throw error;
    return data;
  },
  // Conversations with the PEER's display name resolved server-side (see
  // migration 0011). `i_am_recruiter` tells the UI which name to title with.
  async myConversations() {
    const { data, error } = await requireClient().rpc('my_conversations');
    if (error) throw error;
    return data || [];
  },
  // Open (or fetch) the conversation for a posting+seeker. Requires an open
  // connection (match or accepted invite) — enforced by RLS.
  async openConversation(postingId, seekerId) {
    const c = requireClient();
    const existing = await c.from('conversations').select('id')
      .eq('posting_id', postingId).eq('seeker_id', seekerId).limit(1);
    if (existing.data && existing.data[0]) return existing.data[0].id;
    const { data, error } = await c.from('conversations')
      .insert({ posting_id: postingId, seeker_id: seekerId }).select('id').single();
    if (error) throw error;
    return data.id;
  },
  async listMessages(conversationId) {
    const { data, error } = await requireClient()
      .from('messages').select('id, sender_id, body, created_at, read_at')
      .eq('conversation_id', conversationId).order('created_at');
    if (error) throw error;
    return data;
  },
  async send(conversationId, body) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { data, error } = await c.from('messages')
      .insert({ conversation_id: conversationId, sender_id: u.user.id, body }).select().single();
    if (error) throw error;
    return data;
  },
  // Read receipts: stamp read_at on the OTHER party's unread messages in this
  // conversation (RLS "msg: recipient mark read" allows a participant to update).
  async markRead(conversationId) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    if (!u?.user) return;
    const { error } = await c.from('messages')
      .update({ read_at: new Date().toISOString() })
      .eq('conversation_id', conversationId)
      .neq('sender_id', u.user.id)
      .is('read_at', null);
    if (error) throw error;
  },
  // End-of-chat feedback.
  async submitFeedback({ conversationId = null, experience, professionalism, match, note }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { error } = await c.from('chat_feedback').insert({
      conversation_id: conversationId, rater_id: u.user.id,
      experience, professionalism, match_accuracy: match, note: note || null,
    });
    if (error) throw error;
  },
  // Live updates: invokes cb(message) on each new message. Returns an unsubscribe fn.
  subscribe(conversationId, cb) {
    if (!supabase) return () => {};
    const ch = supabase
      .channel('conv:' + conversationId)
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `conversation_id=eq.${conversationId}` },
        payload => cb(payload.new))
      .subscribe();
    return () => supabase.removeChannel(ch);
  },
};

// ---- Support tickets ------------------------------------------------------
const support = {
  async fileTicket({ type, aboutName = null, aboutId = null, details = '' }) {
    const c = requireClient();
    const { data: u } = await c.auth.getUser();
    const { error } = await c.from('support_tickets').insert({
      reporter_id: u.user?.id, type, about_name: aboutName, about_id: aboutId, details,
    });
    if (error) throw error;
  },
  // People the current user has chatted with (for the abuse-report picker).
  async chattedWith() {
    const c = requireClient();
    const { data, error } = await c.from('conversations')
      .select('id, postings(title, companies(name)), seeker_profiles(profile_id, headline)');
    if (error) throw error;
    return data || [];
  },
};

// ---- Analytics events (write-any; admin-read) -----------------------------
// Per-session visitor meta (browser + referrer + best-effort IP/geo). Captured
// once per browser session; the geo lookup is a third-party call (ipapi.co) and
// is best-effort — events still log without it.
let _meta = null;
function sessionMeta() {
  if (_meta) return _meta;
  // Persistent visitor id (counts a device once across visits) for unique visitors.
  let vid = '';
  try {
    vid = localStorage.getItem('gc_vid') || '';
    if (!vid) {
      vid = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : (Date.now().toString(36) + Math.random().toString(36).slice(2));
      localStorage.setItem('gc_vid', vid);
    }
  } catch (e) {}
  _meta = { ua: navigator.userAgent, ref: document.referrer || '', vid: vid };
  try {
    const cached = sessionStorage.getItem('gc_geo');
    if (cached) Object.assign(_meta, JSON.parse(cached));
  } catch (e) {}
  if (!_meta.country) {
    try {
      fetch('https://ipapi.co/json/').then(r => r.json()).then(g => {
        const geo = { ip: g.ip || '', city: g.city || '', region: g.region || '', country: g.country_name || g.country || '' };
        try { sessionStorage.setItem('gc_geo', JSON.stringify(geo)); } catch (e) {}
        Object.assign(_meta, geo);
      }).catch(() => {});
    } catch (e) {}
  }
  return _meta;
}
const events = {
  // Fire-and-forget: log an analytics event. Never throws to the caller.
  log(type, data = {}) {
    if (!supabase) return;
    const meta = sessionMeta();
    supabase.from('events').insert({ user_id: _uid, type, data: { ...data, ...meta } }).then(() => {}, () => {});
  },
  // Admin: recent events (newest first) for the analytics dashboard.
  async recent(limit = 500) {
    const { data, error } = await requireClient()
      .from('events').select('type, data, created_at')
      .order('created_at', { ascending: false }).limit(limit);
    if (error) throw error;
    return data || [];
  },
  // Admin: aggregated analytics (security-definer RPC; returns null for non-admins).
  // Accepts a number of days (null/7/30/90 for a preset window) OR an options
  // object { days, from, to } where from/to are 'YYYY-MM-DD' strings for an
  // explicit calendar range (range takes precedence over days, inclusive of `to`).
  async analytics(opts = null) {
    let p_days = null, p_from = null, p_to = null;
    if (typeof opts === 'number') p_days = opts;
    else if (opts && typeof opts === 'object') { p_days = opts.days != null ? opts.days : null; p_from = opts.from || null; p_to = opts.to || null; }
    // Only send the range args when a range is set, so the default preset view
    // still resolves against the older admin_analytics(int) before migration 0023
    // is applied. (After 0023 the 3-arg version covers both shapes via defaults.)
    const params = (p_from || p_to) ? { p_days, p_from, p_to } : { p_days };
    const { data, error } = await requireClient().rpc('admin_analytics', params);
    if (error) throw error;
    return data; // jsonb object, or null if not an admin
  },
  // Admin: clear the events log. Returns rows deleted (or -1 if not admin).
  async resetAll() {
    const { data, error } = await requireClient().rpc('admin_reset_events');
    if (error) throw error;
    return data;
  },
  // Admin: list/search registered users. { total, users:[...] } or null for non-admins.
  async users(search) {
    const { data, error } = await requireClient().rpc('admin_users', { p_search: search || null });
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

// Parse a search box string into light boolean parts:
//   "quoted phrases" stay intact · OR (or |) → any-match · leading - or ! excludes.
// Default (no OR) means every positive term must appear. Returns null when empty.
function parseSearch(q) {
  const s = String(q || '').trim();
  if (!s) return null;
  const clean = t => t.replace(/[(),%]/g, ' ').trim();
  const orMode = /\bOR\b/.test(s) || s.includes('|');
  const tokens = []; const re = /"([^"]+)"|(\S+)/g; let m;
  while ((m = re.exec(s))) tokens.push(m[1] != null ? m[1] : m[2]);
  const positives = [], negatives = [];
  tokens.forEach(t => {
    if (t === 'OR' || t === '|') return;
    if ((t[0] === '-' || t[0] === '!') && t.length > 1) { const c = clean(t.slice(1)); if (c) negatives.push(c); }
    else { const c = clean(t); if (c) positives.push(c); }
  });
  if (!positives.length && !negatives.length) return null;
  return { orMode, positives, negatives };
}

// ---- Job board (public read; jobs ingested by the ingest-jobs Edge Function) --
const jobs = {
  // List active jobs, newest first, with optional text search + remote filter.
  // Returns { jobs:[...], total }. total is the full match count (for paging).
  async list({ limit = 20, offset = 0, q = '', remote = null, minSalary = null, employmentType = null, location = null, keywords = null, keywordGroups = null, locationTokens = null, locationOrRemote = false, country = null, sort = 'newest' } = {}) {
    const clean = s => String(s || '').replace(/[(),%]/g, ' ').trim();
    let query = requireClient()
      .from('jobs')
      .select('*', { count: 'exact' })
      .eq('is_active', true);
    if (remote === true) query = query.eq('remote', true);
    // Country filter over free-text location. 'include' = matches any country token;
    // 'exclude' (used for United States, a US-dominant feed) = contains NO foreign
    // token, so "New York, NY" / "Austin, TX" / "United States" all count as US.
    if (country && country.tokens && country.tokens.length) {
      const toks = country.tokens.map(clean).filter(Boolean);
      if (country.mode === 'exclude') query = query.or('location.is.null,and(' + toks.map(t => `location.not.ilike.%${t}%`).join(',') + ')');
      else query = query.or(toks.map(t => `location.ilike.%${t}%`).join(','));
    }
    // employmentType may be a string or an array (multi-select). Stored values are
    // messy free-text from many ATS ('Full time','FullTime','Full-time','Part time',
    // 'Contract'…), so match a normalized keyword per selected type rather than an
    // exact enum (an exact .eq matched ZERO rows — every ATS job got filtered out).
    const empTypes = (Array.isArray(employmentType) ? employmentType : (employmentType ? [employmentType] : [])).filter(Boolean);
    if (empTypes.length) {
      // A job is treated as full-time UNLESS it explicitly says part-time / contract
      // / temp / intern — so blanks, unknowns, and typos ("fulltime","Full Time")
      // all count as full-time. Non-full buckets match their keyword; full-time is
      // the negation of every non-full keyword (plus null). Selected buckets OR together.
      const NON_FULL = ['part', 'contract', 'freelanc', 'tempor', 'seasonal', 'intern'];
      const posFrag = { part_time: ['part'], contract: ['contract', 'freelanc'], temporary: ['tempor', 'seasonal'], internship: ['intern'] };
      const ors = [];
      empTypes.forEach(t => {
        if (t === 'full_time') {
          ors.push('employment_type.is.null');
          ors.push('and(' + NON_FULL.map(k => `employment_type.not.ilike.%${k}%`).join(',') + ')');
        } else {
          (posFrag[t] || [clean(t)]).forEach(k => ors.push(`employment_type.ilike.%${k}%`));
        }
      });
      if (ors.length) query = query.or(ors.join(','));
    }
    if (minSalary) query = query.or(`salary_min.gte.${minSalary},salary_max.gte.${minSalary}`);
    // Text search with light boolean support: "quoted phrases" kept intact, an OR
    // (or |) token switches to any-match, a leading - excludes a term; otherwise all
    // terms must appear. Each term matches title / company / location.
    const parsed = parseSearch(q);
    if (parsed) {
      const fieldsOr = t => `title.ilike.%${t}%,company.ilike.%${t}%,location.ilike.%${t}%`;
      if (parsed.positives.length) {
        if (parsed.orMode) query = query.or(parsed.positives.map(fieldsOr).join(','));
        else parsed.positives.forEach(t => { query = query.or(fieldsOr(t)); });
      }
      // Exclusions: keep a row only if the term is in none of the fields (null-safe).
      parsed.negatives.forEach(t => {
        query = query.or(`title.is.null,title.not.ilike.%${t}%`);
        query = query.or(`company.is.null,company.not.ilike.%${t}%`);
        query = query.or(`location.is.null,location.not.ilike.%${t}%`);
      });
    }
    const loc = clean(location);
    if (loc) query = query.ilike('location', `%${loc}%`);
    // Location tokens (a metro area's cities and/or a typed city): match any token
    // against the location, OR'd with remote so remote roles always surface.
    const locToks = (locationTokens || []).map(clean).filter(Boolean);
    if (locToks.length) {
      const ors = locToks.map(t => `location.ilike.%${t}%`);
      if (locationOrRemote) ors.push('remote.eq.true');
      query = query.or(ors.join(','));
    }
    // keyword GROUPS (e.g. departments, seniority): OR within a group, AND across
    // groups. Falls back to treating a flat `keywords` array as one AND'd group.
    const groups = keywordGroups || (keywords ? [keywords] : []);
    groups.forEach(group => {
      const terms = (group || []).map(clean).filter(Boolean);
      if (!terms.length) return;
      const ors = terms.flatMap(kw => [`title.ilike.%${kw}%`, `description.ilike.%${kw}%`]).join(',');
      query = query.or(ors);
    });
    if (sort === 'salary') query = query.order('salary_max', { ascending: false, nullsFirst: false });
    else if (sort === 'alpha') query = query.order('title', { ascending: true });
    else query = query.order('posted_at', { ascending: false, nullsFirst: false }); // newest (default)
    query = query.range(offset, offset + limit - 1);
    const { data, error, count } = await query;
    if (error) throw error;
    return { jobs: data || [], total: count ?? 0 };
  },
  // Relevance-ranked search (jobs_search RPC). Pass the seeker's keywords joined
  // with " or " for "Recommended for you". Returns an array of jobs, best first.
  async search({ q = '', remote = null, limit = 12, offset = 0 } = {}) {
    const { data, error } = await requireClient().rpc('jobs_search', {
      p_q: q || null,
      p_remote: remote === true ? true : null,
      p_limit: limit,
      p_offset: offset,
    });
    if (error) throw error;
    return data || [];
  },
};

// ---- Personal job tracker (saved / applied) — private to each user ----------
const tracker = {
  async list() {
    const c = requireClient(); const { data: u } = await c.auth.getUser();
    if (!u?.user) return [];
    const { data, error } = await c.from('tracked_jobs').select('*')
      .eq('user_id', u.user.id).order('updated_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },
  // Upsert a tracked job (from a feed job object) with a status ('saved'|'applied').
  async save(job, status = 'saved') {
    const c = requireClient(); const { data: u } = await c.auth.getUser();
    const row = {
      user_id: u.user.id, job_id: job.id || null,
      title: job.title || 'Untitled role', company: job.company || null,
      location: job.location || null, url: job.url || null,
      status, applied_at: status === 'applied' ? new Date().toISOString() : null,
    };
    const { data, error } = await c.from('tracked_jobs').upsert(row, { onConflict: 'user_id,job_id' }).select().single();
    if (error) throw error;
    return data;
  },
  async setStatus(id, status) {
    const { data, error } = await requireClient().from('tracked_jobs')
      .update({ status, applied_at: status === 'applied' ? new Date().toISOString() : null })
      .eq('id', id).select().single();
    if (error) throw error;
    return data;
  },
  async removeByJob(jobId) {
    const c = requireClient(); const { data: u } = await c.auth.getUser();
    const { error } = await c.from('tracked_jobs').delete().eq('user_id', u.user.id).eq('job_id', jobId);
    if (error) throw error;
  },
  async remove(id) {
    const { error } = await requireClient().from('tracked_jobs').delete().eq('id', id);
    if (error) throw error;
  },
};

// ---- Per-user preferences (saved filters, etc.) — private to each user --------
const prefs = {
  async get() {
    const c = requireClient(); const { data: u } = await c.auth.getUser();
    if (!u?.user) return null;
    const { data, error } = await c.from('user_prefs').select('prefs').eq('user_id', u.user.id).limit(1);
    if (error) throw error;
    return (data && data[0]) ? data[0].prefs : null;
  },
  async set(prefsObj) {
    const c = requireClient(); const { data: u } = await c.auth.getUser();
    if (!u?.user) return;
    const { error } = await c.from('user_prefs')
      .upsert({ user_id: u.user.id, prefs: prefsObj, updated_at: new Date().toISOString() }, { onConflict: 'user_id' });
    if (error) throw error;
  },
};

window.GigCuteAPI = {
  enabled,
  supabase,
  prefs,
  auth, profiles, seeker, companies, postings, interest, invites, eeo, reference, reports, admin, verification, chat, support, events, jobs, tracker,
  isFreeEmailDomain,
};

// Let the inline app know the API is ready (it may load after this module).
window.dispatchEvent(new CustomEvent('gigcute-api-ready'));

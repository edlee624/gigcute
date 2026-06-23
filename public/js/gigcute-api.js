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
};

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
  auth, profiles, seeker, companies, postings, interest, invites, eeo, reference, reports,
};

// Let the inline app know the API is ready (it may load after this module).
window.dispatchEvent(new CustomEvent('gigcute-api-ready'));

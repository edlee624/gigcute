-- ============================================================================
-- GigCute — reference data
-- The shared prompt bank and screening-question templates (incl. the voluntary
-- EEO / DE&I self-identification templates). These mirror the constants the
-- frontend currently hard-codes; once seeded, the app can read them from here.
-- ============================================================================

insert into public.prompt_bank (id, label) values
  (1,  'My superpower at work'),
  (2,  'I''m proudest of'),
  (3,  'Looking for a team that'),
  (4,  'A mistake that taught me the most'),
  (5,  'My ideal manager'),
  (6,  'Outside of work, I'),
  (7,  'The tool I can''t live without'),
  (8,  'On a typical Tuesday, I'),
  (9,  'I work best when'),
  (10, 'The skill I''m still building'),
  (11, 'A project I''d love to talk about'),
  (12, 'My non-negotiable'),
  (13, 'I geek out about'),
  (14, 'The feedback that changed how I work'),
  (15, 'My biggest career pivot'),
  (16, 'I''m the person people come to for'),
  (17, 'A risk that paid off'),
  (18, 'What gets me out of bed in the morning'),
  (19, 'My work style in three words'),
  (20, 'The hardest thing I''ve shipped'),
  (21, 'I learn best by'),
  (22, 'A belief I''ve changed my mind on'),
  (23, 'The kind of problems I want to solve next'),
  (24, 'My favorite part of the day'),
  (25, 'I''m currently learning'),
  (26, 'A team I''d love to be part of'),
  (27, 'What success looks like to me'),
  (28, 'The thing I wish more interviewers asked me'),
  (29, 'My pet peeve at work'),
  (30, 'Two truths and a lie about my work style')
on conflict (id) do nothing;

-- Regular screening templates (tier-limited) ---------------------------------
insert into public.screening_templates (id, label, question, type, fill_label, placeholder, ideal, is_voluntary, sort_order) values
  ('background-check', 'Background Check',     'Are you willing to undergo a background check, in accordance with local law/regulations?', 'yesno', null, null, 'Yes', false, 1),
  ('certifications',   'Certifications',       'Do you have the following license or certification?', 'fill-yesno', 'License / Certification', 'e.g. PMP, AWS Solutions Architect', 'Yes', false, 2),
  ('drivers-license',  'Driver''s License',    'Do you have a valid driver''s license?', 'yesno', null, null, 'Yes', false, 3),
  ('drug-test',        'Drug Test',            'Are you willing to take a drug test, in accordance with local law/regulations?', 'yesno', null, null, 'Yes', false, 4),
  ('education',        'Education',            'Have you completed the following level of education?', 'education', null, null, 'Yes', false, 5),
  ('skill-exp',        'Expertise with Skill', 'How many years of work experience do you have with [Skill]?', 'fill-minyears', 'Skill', 'e.g. Python, Figma, SQL', null, false, 6),
  ('gpa',              'GPA',                  'What is your university grade point average (4.0 GPA Scale)?', 'min-number', 'Minimum GPA', 'e.g. 3.0', null, false, 7),
  ('hybrid-work',      'Hybrid Work',          'Are you comfortable working in a hybrid setting?', 'yesno', null, null, 'Yes', false, 8),
  ('industry-exp',     'Industry Experience',  'How many years of [Industry] experience do you currently have?', 'fill-minyears', 'Industry', 'e.g. Healthcare, Fintech, SaaS', null, false, 9),
  ('language',         'Language',             'What is your level of proficiency in [Language]?', 'language', 'Language', 'e.g. Spanish, Mandarin', null, false, 10),
  ('location',         'Location',             'Are you comfortable commuting to this job''s location?', 'yesno', null, null, 'Yes', false, 11),
  ('onsite-work',      'Onsite Work',          'Are you comfortable working in an onsite setting?', 'yesno', null, null, 'Yes', false, 12),
  ('remote-work',      'Remote Work',          'Are you comfortable working in a remote setting?', 'yesno', null, null, 'Yes', false, 13),
  ('urgent-hiring',    'Urgent Hiring Need',   '', 'custom', null, 'Describe your urgent hiring requirement…', null, false, 14),
  ('visa-status',      'Visa Status',          'Will you now, or in the future, require sponsorship for employment visa status (e.g. H-1B)?', 'yesno', null, null, 'No', false, 15),
  ('work-auth',        'Work Authorization',   'Are you legally authorized to work in the United States?', 'yesno', null, null, 'Yes', false, 16),
  ('job-function-exp', 'Work Experience',      'How many years of [Job Function] experience do you currently have?', 'fill-minyears', 'Job Function', 'e.g. Product Management, Engineering', null, false, 17),
  ('custom',           'Custom Question',      '', 'custom', null, 'Write your own screening question…', null, false, 18)
on conflict (id) do nothing;

-- Voluntary self-identification (EEO / DE&I) templates -----------------------
-- Available on every tier; never used to screen, rank, or reject.
insert into public.screening_templates (id, label, question, type, is_voluntary, options, sort_order) values
  ('eeo-gender',     'Gender',            'How do you describe your gender identity? (Voluntary)',                  'voluntary', true,
    array['Man','Woman','Non-binary','Prefer to self-describe','Decline to self-identify'], 100),
  ('eeo-ethnicity',  'Race / Ethnicity',  'Which race or ethnicity best describes you? (Voluntary)',                'voluntary', true,
    array['Hispanic or Latino','White','Black or African American','Asian','Native American or Alaska Native','Native Hawaiian or Other Pacific Islander','Two or more races','Decline to self-identify'], 101),
  ('eeo-veteran',    'Veteran Status',    'Do you identify as a protected veteran? (Voluntary)',                    'voluntary', true,
    array['I am a protected veteran','I am not a protected veteran','Decline to self-identify'], 102),
  ('eeo-disability', 'Disability Status', 'Do you have a disability, or have you had one in the past? (Voluntary)', 'voluntary', true,
    array['Yes','No','Decline to self-identify'], 103)
on conflict (id) do nothing;

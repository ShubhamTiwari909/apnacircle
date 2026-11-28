-- Preserve the existing RLS-scoped reads. Responses omit staff attribution and internal notes.
grant select on public.grievances to authenticated;
grant select(id,grievance_id,action,response,created_at) on public.grievance_responses to authenticated;

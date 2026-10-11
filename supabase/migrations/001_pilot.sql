begin;
create schema if not exists private;
revoke all on schema private from public;
create table public.lenders(id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 120), status text not null default 'pending' check(status in ('pending','active','declined')), created_at timestamptz not null default now());
create table public.partners(id uuid primary key default gen_random_uuid(), name text not null, status text not null default 'active' check(status in ('active','inactive')));
create table public.memberships(user_id uuid primary key references auth.users(id), role text not null check(role in ('admin','lender','partner')), lender_id uuid references public.lenders(id), partner_id uuid references public.partners(id), active boolean not null default true, check((role='admin' and lender_id is null and partner_id is null) or (role='lender' and lender_id is not null and partner_id is null) or (role='partner' and partner_id is not null and lender_id is null)));
create table public.allocations(id uuid primary key default gen_random_uuid(), lender_id uuid not null references public.lenders(id), title text not null check(length(title) between 1 and 120), capital_centavos bigint not null check(capital_centavos between 1 and 1000000000000), borrower_count int not null check(borrower_count between 1 and 10000), ticket_centavos bigint not null check(ticket_centavos>0), terms jsonb not null default '{}' check(jsonb_typeof(terms)='object'), status text not null default 'submitted' check(status in ('submitted','changes_requested','declined','approved','funding_verified')), review_note text, funding_reference text, created_at timestamptz not null default now(), check(capital_centavos=ticket_centavos*borrower_count));
create table public.borrowers(id uuid primary key default gen_random_uuid(), partner_id uuid not null references public.partners(id), account_number text not null unique check(length(account_number) between 1 and 80), profile jsonb not null default '{}', consent_at timestamptz not null, created_at timestamptz not null default now());
create table public.applications(id uuid primary key default gen_random_uuid(), borrower_id uuid not null references public.borrowers(id), allocation_id uuid references public.allocations(id), status text not null default 'submitted' check(status in ('submitted','qualified','candidate','with_lender','approved','declined','released')), review_note text, created_at timestamptz not null default now());
-- One active application per borrower; a declined application may be replaced.
create unique index applications_one_active on public.applications(borrower_id) where status<>'declined';
create table public.disbursements(id uuid primary key default gen_random_uuid(), application_id uuid not null unique references public.applications(id), amount_centavos bigint not null check(amount_centavos>0), status text not null default 'simulated' check(status='simulated'), created_at timestamptz not null default now());
create table public.payments(id uuid primary key default gen_random_uuid(), application_id uuid not null references public.applications(id), amount_centavos bigint not null check(amount_centavos>0), external_reference text not null unique, status text not null default 'pending' check(status in ('pending','reconciled','rejected')), received_at timestamptz not null default now());
create table public.audit_records(id bigint generated always as identity primary key, actor_id uuid not null references auth.users(id), entity_type text not null, entity_id uuid not null, action text not null, details jsonb not null default '{}', created_at timestamptz not null default now());
create table private.commands(actor_id uuid not null, request_id uuid not null, fingerprint jsonb not null, result jsonb not null, primary key(actor_id,request_id));
create function private.member() returns public.memberships language sql stable security definer set search_path='' as $$ select m from public.memberships m where m.user_id=auth.uid() and m.active $$;
create function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$ select coalesce((private.member()).role='admin',false) $$;
create function private.can_allocation(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$ select private.is_admin() or exists(select 1 from public.allocations a where a.id=p_id and a.lender_id=(private.member()).lender_id) $$;
create function private.can_application(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$ select private.is_admin() or exists(select 1 from public.applications a join public.borrowers b on b.id=a.borrower_id where a.id=p_id and (b.partner_id=(private.member()).partner_id or (a.status in ('with_lender','approved','declined','released') and private.can_allocation(a.allocation_id)))) $$;
-- No user-supplied role or tenant is trusted. All commands derive membership from auth.uid().
create function public.pilot_command(p_action text,p_entity_id uuid default null,p_payload jsonb default '{}',p_request_id uuid default gen_random_uuid()) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.memberships; a public.allocations; app public.applications; lid uuid; bid uuid; eid uuid; result jsonb; old private.commands; fp jsonb; used bigint; slots int; cap bigint; cnt int; p public.payments;
begin
 m:=private.member(); if m.user_id is null then raise exception 'Active membership required' using errcode='42501'; end if;
 if p_request_id is null or p_action is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Invalid command'; end if;
 fp:=jsonb_build_object('action',p_action,'id',p_entity_id,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(m.user_id::text||p_request_id::text,0));
 select * into old from private.commands where actor_id=m.user_id and request_id=p_request_id;
 if found then if old.fingerprint<>fp then raise exception 'Request ID reused with different command'; end if; return old.result; end if;
 if p_action='create_allocation' then
  if m.role<>'lender' then raise exception 'Lender role required' using errcode='42501'; end if;
  select id into lid from public.lenders where id=m.lender_id and status='active' for update;
  if lid is null then raise exception 'Lender must be active'; end if;
  cap:=(p_payload->>'capital_centavos')::bigint;cnt:=(p_payload->>'borrower_count')::int;
  if cap is null or cnt is null or cap<=0 or cnt<=0 or mod(cap,cnt)<>0 then raise exception 'Capital must divide equally into whole centavos'; end if;
  insert into public.allocations(lender_id,title,capital_centavos,borrower_count,ticket_centavos,terms) values(lid,trim(p_payload->>'title'),cap,cnt,cap/cnt,coalesce(p_payload->'terms','{}')) returning id into eid;
 elsif p_action in ('activate_lender','decline_lender') then
  if m.role<>'admin' then raise exception 'Admin role required' using errcode='42501'; end if;
  update public.lenders set status=case when p_action='activate_lender' then 'active' else 'declined' end where id=p_entity_id and status='pending' returning id into eid;
  if eid is null then raise exception 'Lender is not pending'; end if;
 elsif p_action in ('approve_allocation','request_changes','decline_allocation','verify_funding','resubmit_allocation') then
  select * into a from public.allocations where id=p_entity_id for update;
  if a.id is null then raise exception 'Allocation unavailable'; end if;
  if p_action='resubmit_allocation' then
   if m.role<>'lender' or m.lender_id<>a.lender_id then raise exception 'Allocation owner required' using errcode='42501'; end if;
   if a.status<>'changes_requested' or length(trim(coalesce(p_payload->>'note','')))=0 then raise exception 'Requested changes and response required'; end if;
   update public.allocations set status='submitted' where id=a.id;
  else
   if m.role<>'admin' then raise exception 'Admin role required' using errcode='42501'; end if;
   if p_action='verify_funding' then
    if a.status<>'approved' or length(trim(coalesce(p_payload->>'reference','')))=0 then raise exception 'Approval and sample reference required'; end if;
    update public.allocations set status='funding_verified',funding_reference=trim(p_payload->>'reference') where id=a.id;
   else
    if a.status<>'submitted' then raise exception 'Allocation must be submitted'; end if;
    if p_action<>'approve_allocation' and length(trim(coalesce(p_payload->>'note','')))=0 then raise exception 'Review note required'; end if;
    update public.allocations set status=case p_action when 'approve_allocation' then 'approved' when 'request_changes' then 'changes_requested' else 'declined' end, review_note=p_payload->>'note' where id=a.id;
   end if;
  end if; eid:=a.id;
 elsif p_action='create_application' then
  if m.role<>'partner' then raise exception 'Partner role required' using errcode='42501'; end if;
  if not exists(select 1 from public.partners where id=m.partner_id and status='active') then raise exception 'Partner inactive'; end if;
  if coalesce((p_payload->>'consent')::boolean,false)=false then raise exception 'Borrower consent required'; end if;
  insert into public.borrowers(partner_id,account_number,profile,consent_at) values(m.partner_id,trim(p_payload->>'account_number'),coalesce(p_payload->'profile','{}'),now()) returning id into bid;
  insert into public.applications(borrower_id) values(bid) returning id into eid;
 elsif p_action in ('qualify_application','match_application','submit_application','approve_application','decline_application','simulate_release') then
  -- Read allocation ID, lock allocation before application: consistent order serializes capacity checks.
  select allocation_id into lid from public.applications where id=p_entity_id;
  if p_action='match_application' then lid:=(p_payload->>'allocation_id')::uuid; end if;
  if lid is not null then select * into a from public.allocations where id=lid for update; end if;
  select * into app from public.applications where id=p_entity_id for update;
  if app.id is null then raise exception 'Application unavailable'; end if;
  if p_action in ('qualify_application','match_application','submit_application') then
   if m.role<>'admin' then raise exception 'Admin role required' using errcode='42501'; end if;
   if p_action='qualify_application' then
    if app.status<>'submitted' then raise exception 'Application must be submitted'; end if;
    update public.applications set status='qualified',review_note=p_payload->>'note' where id=app.id;
   elsif p_action='match_application' then
    if app.status<>'qualified' or a.id is null or a.status<>'funding_verified' then raise exception 'Qualified application and verified allocation required'; end if;
    select count(*) into slots from public.applications where allocation_id=a.id and status in ('candidate','with_lender','approved','released');
    if slots>=a.borrower_count then raise exception 'Allocation capacity reached'; end if;
    update public.applications set status='candidate',allocation_id=a.id where id=app.id;
   else
    if app.status<>'candidate' or a.status<>'funding_verified' then raise exception 'Candidate and verified allocation required'; end if;
    update public.applications set status='with_lender' where id=app.id;
   end if;
  else
   if m.role<>'lender' or a.id is null or m.lender_id<>a.lender_id then raise exception 'Allocation owner required' using errcode='42501'; end if;
   if p_action='simulate_release' then
    if app.status<>'approved' then raise exception 'Application must be approved'; end if;
    insert into public.disbursements(application_id,amount_centavos) values(app.id,a.ticket_centavos);
    update public.applications set status='released' where id=app.id;
   else
    if app.status<>'with_lender' then raise exception 'Application must be with lender'; end if;
    if p_action='decline_application' and length(trim(coalesce(p_payload->>'note','')))=0 then raise exception 'Decline reason required'; end if;
    if p_action='approve_application' then
     select coalesce(sum(case when x.status in ('approved','released') then a.ticket_centavos else 0 end),0) into used from public.applications x where x.allocation_id=a.id;
     if used+a.ticket_centavos>a.capital_centavos then raise exception 'Insufficient unreserved capital'; end if;
    end if;
    update public.applications set status=case when p_action='approve_application' then 'approved' else 'declined' end,review_note=p_payload->>'note' where id=app.id;
   end if;
  end if;eid:=app.id;
 elsif p_action='record_payment' then
  if m.role<>'admin' then raise exception 'Admin role required' using errcode='42501'; end if;
  if not exists(select 1 from public.applications where id=p_entity_id and status='released') then raise exception 'Released application required'; end if;
  if length(trim(coalesce(p_payload->>'reference','')))=0 then raise exception 'Unique payment reference required'; end if;
  insert into public.payments(application_id,amount_centavos,external_reference) values(p_entity_id,(p_payload->>'amount_centavos')::bigint,trim(p_payload->>'reference')) returning id into eid;
 elsif p_action in ('reconcile_payment','reject_payment') then
  if m.role<>'admin' then raise exception 'Admin role required' using errcode='42501'; end if;
  select * into p from public.payments where id=p_entity_id for update;
  if p.id is null or p.status<>'pending' then raise exception 'Payment must be pending'; end if;
  update public.payments set status=case when p_action='reconcile_payment' then 'reconciled' else 'rejected' end where id=p.id;eid:=p.id;
 else raise exception 'Unknown command'; end if;
 result:=jsonb_build_object('id',eid,'action',p_action);
 insert into public.audit_records(actor_id,entity_type,entity_id,action,details) values(m.user_id,case when p_action like '%allocation' or p_action='verify_funding' then 'allocation' when p_action like '%lender' then 'lender' when p_action like '%payment' then 'payment' else 'application' end,eid,p_action,p_payload - 'profile');
 insert into private.commands values(m.user_id,p_request_id,fp,result);
 return result;
end $$;
-- Read access only. Mutations require the command function and its actor/state checks.
alter table public.lenders enable row level security;
alter table public.partners enable row level security;
alter table public.memberships enable row level security;
alter table public.allocations enable row level security;
alter table public.borrowers enable row level security;
alter table public.applications enable row level security;
alter table public.disbursements enable row level security;
alter table public.payments enable row level security;
alter table public.audit_records enable row level security;
create policy membership_read on public.memberships for select to authenticated using(user_id=auth.uid() or private.is_admin());
create policy lender_read on public.lenders for select to authenticated using(private.is_admin() or id=(private.member()).lender_id);
create policy partner_read on public.partners for select to authenticated using(private.is_admin() or id=(private.member()).partner_id);
create policy allocation_read on public.allocations for select to authenticated using(private.can_allocation(id));
create policy borrower_read on public.borrowers for select to authenticated using(private.is_admin() or partner_id=(private.member()).partner_id);
create policy application_read on public.applications for select to authenticated using(private.can_application(id));
create policy disbursement_read on public.disbursements for select to authenticated using(private.can_application(application_id));
create policy payment_read on public.payments for select to authenticated using(private.can_application(application_id));
create policy audit_read on public.audit_records for select to authenticated using(private.is_admin());
revoke all on all tables in schema public from anon,authenticated;
grant select on public.lenders,public.partners,public.memberships,public.allocations,public.borrowers,public.applications,public.disbursements,public.payments,public.audit_records to authenticated;
revoke all on function public.pilot_command(text,uuid,jsonb,uuid) from public,anon;
grant execute on function public.pilot_command(text,uuid,jsonb,uuid) to authenticated;
revoke all on all functions in schema private from public,anon;
grant usage on schema private to authenticated;
grant execute on function private.member(),private.is_admin(),private.can_allocation(uuid),private.can_application(uuid) to authenticated;
commit;

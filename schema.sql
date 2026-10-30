-- ============================================================
--  桜算法手帳 · Supabase 数据库结构与权限
--  用法：Supabase 控制台 → SQL Editor → New query → 粘贴全文 → Run
--  可重复执行（幂等）。执行完把 Project URL 与 anon key 填到
--  public/supabase.config.json（或 .env 的 PUBLIC_SUPABASE_*）。
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- 1. 用户资料 ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  nickname      text not null unique check (char_length(nickname) between 2 and 24),
  bio           text not null default '' check (char_length(bio) <= 240),
  avatar        text not null default '🌸' check (char_length(avatar) <= 8),
  accent        text not null default 'sakura'
                check (accent in ('sakura','lavender','sky','mint','gold','sunset')),
  cf_handle     text not null default '' check (char_length(cf_handle) <= 40),
  luogu_handle  text not null default '' check (char_length(luogu_handle) <= 40),
  school        text not null default '' check (char_length(school) <= 60),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------- 2. 社区帖子 ----------
create table if not exists public.posts (
  id           uuid primary key default gen_random_uuid(),
  author       uuid not null references public.profiles (id) on delete cascade,
  kind         text not null default 'note'
               check (kind in ('note','upsolve','question','daily')),
  title        text not null check (char_length(title) between 2 and 80),
  body         text not null check (char_length(body) between 2 and 12000),
  tags         text[] not null default '{}',
  problem_url  text not null default '',
  created_at   timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_author_idx on public.posts (author);

-- ---------- 3. 评论 ----------
create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  post       uuid not null references public.posts (id) on delete cascade,
  author     uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post, created_at);

-- ---------- 4. 点赞 / 关注 ----------
create table if not exists public.likes (
  post uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post, user_id)
);

create table if not exists public.follows (
  follower  uuid not null references public.profiles (id) on delete cascade,
  following uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, following),
  check (follower <> following)
);

-- ---------- 5. 学习进度（云端同步） ----------
create table if not exists public.learning_state (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  state      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ---------- 6. 自动建资料 ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base text;
  nick text;
  i    int := 0;
begin
  base := coalesce(nullif(trim(new.raw_user_meta_data ->> 'nickname'), ''), '喵友');
  if char_length(base) < 2 then
    base := base || '喵';
  end if;
  base := left(base, 18);
  nick := base;
  while exists (select 1 from public.profiles p where p.nickname = nick) loop
    i := i + 1;
    nick := left(base, 16) || i::text;
  end loop;

  insert into public.profiles (id, nickname, avatar, bio)
  values (
    new.id,
    nick,
    coalesce(nullif(new.raw_user_meta_data ->> 'avatar', ''), '🌸'),
    coalesce(nullif(new.raw_user_meta_data ->> 'bio', ''), '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 7. updated_at ----------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------- 8. RLS ----------
alter table public.profiles       enable row level security;
alter table public.posts          enable row level security;
alter table public.comments       enable row level security;
alter table public.likes          enable row level security;
alter table public.follows        enable row level security;
alter table public.learning_state enable row level security;

-- profiles：人人可读，只能改自己
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (true);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles for insert with check (auth.uid() = id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update
  using (auth.uid() = id) with check (auth.uid() = id);

-- posts：人人可读，写/改/删仅作者
drop policy if exists posts_read on public.posts;
create policy posts_read on public.posts for select using (true);

drop policy if exists posts_insert_own on public.posts;
create policy posts_insert_own on public.posts for insert with check (auth.uid() = author);

drop policy if exists posts_update_own on public.posts;
create policy posts_update_own on public.posts for update
  using (auth.uid() = author) with check (auth.uid() = author);

drop policy if exists posts_delete_own on public.posts;
create policy posts_delete_own on public.posts for delete using (auth.uid() = author);

-- comments：人人可读，写仅本人，删本人
drop policy if exists comments_read on public.comments;
create policy comments_read on public.comments for select using (true);

drop policy if exists comments_insert_own on public.comments;
create policy comments_insert_own on public.comments for insert with check (auth.uid() = author);

drop policy if exists comments_delete_own on public.comments;
create policy comments_delete_own on public.comments for delete using (auth.uid() = author);

-- likes：人人可读，只能操作自己的点赞
drop policy if exists likes_read on public.likes;
create policy likes_read on public.likes for select using (true);

drop policy if exists likes_insert_own on public.likes;
create policy likes_insert_own on public.likes for insert with check (auth.uid() = user_id);

drop policy if exists likes_delete_own on public.likes;
create policy likes_delete_own on public.likes for delete using (auth.uid() = user_id);

-- follows：人人可读，只能关注/取关自己那一行
drop policy if exists follows_read on public.follows;
create policy follows_read on public.follows for select using (true);

drop policy if exists follows_insert_own on public.follows;
create policy follows_insert_own on public.follows for insert with check (auth.uid() = follower);

drop policy if exists follows_delete_own on public.follows;
create policy follows_delete_own on public.follows for delete using (auth.uid() = follower);

-- learning_state：只有自己可读写
drop policy if exists state_read_own on public.learning_state;
create policy state_read_own on public.learning_state for select using (auth.uid() = user_id);

drop policy if exists state_insert_own on public.learning_state;
create policy state_insert_own on public.learning_state for insert with check (auth.uid() = user_id);

drop policy if exists state_update_own on public.learning_state;
create policy state_update_own on public.learning_state for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- 9. 便捷视图：帖子 + 作者 + 计数 ----------
create or replace view public.post_feed
with (security_invoker = true) as
select
  p.id, p.kind, p.title, p.body, p.tags, p.problem_url, p.created_at,
  p.author,
  pr.nickname, pr.avatar, pr.accent,
  (select count(*) from public.likes    l where l.post = p.id) as like_count,
  (select count(*) from public.comments c where c.post = p.id) as comment_count
from public.posts p
join public.profiles pr on pr.id = p.author;

grant select on public.post_feed to anon, authenticated;

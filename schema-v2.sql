-- ============================================================
-- 桜算法手帐 v2：GitHub 一键登录 + 头像上传 + 个人档案
-- 在 Supabase → SQL Editor 里整段执行（可重复执行，幂等）
-- ============================================================

-- 1) 头像列从「emoji（≤8 字符）」升级为「emoji 或图片 URL」
alter table public.profiles drop constraint if exists profiles_avatar_check;

alter table public.profiles
  add constraint profiles_avatar_check check (char_length(avatar) between 1 and 300);

-- 2) 新建账号时自动建档案：兼容 GitHub OAuth 返回的元数据
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  base text;
  nick text;
  n int := 1;
begin
  base := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'nickname'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'user_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'preferred_username'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    '喵友'
  );
  -- 昵称长度限制 2..24
  base := left(base, 20);
  if char_length(base) < 2 then
    base := '喵友';
  end if;

  nick := base;
  while exists (select 1 from public.profiles p where p.nickname = nick) loop
    n := n + 1;
    nick := base || n::text;
  end loop;

  insert into public.profiles (id, nickname, avatar, bio)
  values (
    new.id,
    nick,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'avatar', ''),
      nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
      '🌸'
    ),
    ''
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- 3) 头像存储桶：公开可读，登录用户只能写自己目录
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp', 'image/gif'];

drop policy if exists "avatars public read"   on storage.objects;
drop policy if exists "avatars own insert"    on storage.objects;
drop policy if exists "avatars own update"    on storage.objects;
drop policy if exists "avatars own delete"    on storage.objects;

create policy "avatars public read"
  on storage.objects for select
  using (bucket_id = 'avatars');

create policy "avatars own insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars own update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars own delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 完成。回网站刷新一下，就能用 GitHub 登录、上传头像了。

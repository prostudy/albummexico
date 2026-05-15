-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  ÁLBUM MÉXICO — Schema Supabase                                       ║
-- ║  Corre este archivo en Supabase SQL Editor de un jalón.              ║
-- ║  Es idempotente: lo puedes volver a correr sin romper nada.          ║
-- ╚══════════════════════════════════════════════════════════════════════╝

-- ─────────────────────────────────────────────────────────────────────
-- 0.  EXTENSIONES
-- ─────────────────────────────────────────────────────────────────────
create extension if not exists "pgcrypto";    -- gen_random_uuid()
create extension if not exists "cube";        -- requerido por earthdistance
create extension if not exists "earthdistance"; -- distancia geográfica (opcional, para "cerca de mí")

-- ─────────────────────────────────────────────────────────────────────
-- 1.  TABLAS DE CONTENIDO  (públicas, solo lectura para usuarios)
-- ─────────────────────────────────────────────────────────────────────

-- Estados de México (32 registros)
create table if not exists public.states (
  id          int          primary key,         -- viene del JSON original
  clave       text         not null,            -- 'CMX', 'AGU', etc.
  slug        text         unique not null,     -- 'ciudad-de-mexico'
  name        text         not null,
  region      text         not null,            -- 'Centro', 'Bajío', 'Norte', 'Pacífico', 'Sur', 'Península'
  image_url   text,
  link        text,
  lat         double precision,
  lng         double precision,
  created_at  timestamptz  default now()
);

create index if not exists idx_states_region on public.states(region);
create index if not exists idx_states_slug   on public.states(slug);

-- Destinos (≈ 250 registros del JSON)
create table if not exists public.places (
  id                  int          primary key,
  state_id            int          references public.states(id) on delete cascade,
  state_slug          text         not null,
  slug                text         not null,
  name                text         not null,
  link                text,
  image_url           text,
  is_pueblo_magico    boolean      default false,
  place_type          text,         -- 'city', 'neighborhood', 'beach', 'nature', 'destination', 'pueblo_magico'
  lat                 double precision,
  lng                 double precision,
  -- opcionales (se llenan con enrich.py)
  summary             text,
  description_html    text,
  gallery_urls        text[],
  created_at          timestamptz  default now(),
  -- unique por estado+slug para idempotencia
  unique (state_slug, slug)
);

create index if not exists idx_places_state    on public.places(state_id);
create index if not exists idx_places_pm       on public.places(is_pueblo_magico) where is_pueblo_magico;
create index if not exists idx_places_geo      on public.places using gist (ll_to_earth(lat, lng))
  where lat is not null and lng is not null;

-- ─────────────────────────────────────────────────────────────────────
-- 2.  PERFIL DE USUARIO
-- ─────────────────────────────────────────────────────────────────────

create table if not exists public.profiles (
  id            uuid         primary key references auth.users(id) on delete cascade,
  handle        text         unique,                          -- 'ana123', se asigna al primer login
  display_name  text,
  avatar_seed   text         default gen_random_uuid()::text, -- para avatars generativos consistentes
  is_public     boolean      default true,                    -- perfil compartible
  created_at    timestamptz  default now(),
  updated_at    timestamptz  default now()
);

create index if not exists idx_profiles_handle on public.profiles(handle);

-- Genera un handle único al crear el usuario (ej. "viajero-a3f4")
create or replace function public.generate_handle()
returns text language plpgsql as $$
declare
  candidate text;
  attempts  int := 0;
begin
  loop
    candidate := 'viajero-' || lower(substring(gen_random_uuid()::text, 1, 6));
    perform 1 from public.profiles where handle = candidate;
    if not found then
      return candidate;
    end if;
    attempts := attempts + 1;
    if attempts > 10 then
      return 'viajero-' || extract(epoch from now())::bigint;
    end if;
  end loop;
end $$;

-- Trigger: cada vez que se crea un auth.user, se crea su profile
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, handle)
  values (new.id, public.generate_handle())
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────────────
-- 3.  EL CORAZÓN DEL ÁLBUM: estado de cada lugar por usuario
-- ─────────────────────────────────────────────────────────────────────

create type public.place_state as enum ('wanted', 'visited', 'loved');

create table if not exists public.user_place_states (
  user_id     uuid                references public.profiles(id) on delete cascade,
  place_id    int                 references public.places(id)   on delete cascade,
  state       public.place_state  not null,
  visited_at  timestamptz,                   -- la fecha que el usuario eligió (no necesariamente "ahora")
  note        text,                          -- nota personal opcional
  is_private  boolean             default false,
  created_at  timestamptz         default now(),
  updated_at  timestamptz         default now(),
  primary key (user_id, place_id)
);

create index if not exists idx_ups_user  on public.user_place_states(user_id);
create index if not exists idx_ups_place on public.user_place_states(place_id);
create index if not exists idx_ups_state on public.user_place_states(state);

-- Auto-update updated_at
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_ups_updated on public.user_place_states;
create trigger trg_ups_updated
  before update on public.user_place_states
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_profile_updated on public.profiles;
create trigger trg_profile_updated
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ─────────────────────────────────────────────────────────────────────
-- 4.  ESTADÍSTICAS AGREGADAS (vista materializable a futuro)
-- ─────────────────────────────────────────────────────────────────────

create or replace view public.place_stats as
select
  p.id              as place_id,
  count(*) filter (where ups.state = 'wanted')   as wanted_count,
  count(*) filter (where ups.state = 'visited')  as visited_count,
  count(*) filter (where ups.state = 'loved')    as loved_count,
  count(*) filter (where ups.state in ('visited','loved') and ups.created_at > now() - interval '24 hours') as trending_24h
from public.places p
left join public.user_place_states ups on ups.place_id = p.id
group by p.id;

-- ─────────────────────────────────────────────────────────────────────
-- 5.  ROW LEVEL SECURITY  (la magia de Supabase)
-- ─────────────────────────────────────────────────────────────────────

-- States y places son públicos (read-only para anon)
alter table public.states enable row level security;
alter table public.places enable row level security;

drop policy if exists "states_public_read"  on public.states;
drop policy if exists "places_public_read"  on public.places;
create policy "states_public_read" on public.states for select to anon, authenticated using (true);
create policy "places_public_read" on public.places for select to anon, authenticated using (true);

-- Profiles: visible públicamente si is_public, editable solo por su dueño
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_public"  on public.profiles;
drop policy if exists "profiles_update_own"     on public.profiles;
drop policy if exists "profiles_select_own"     on public.profiles;
create policy "profiles_select_public" on public.profiles for select to anon, authenticated
  using (is_public or auth.uid() = id);
create policy "profiles_update_own"    on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- user_place_states: cada quien ve y modifica las suyas; las "no-privadas" de otros se ven públicas (para perfil compartido)
alter table public.user_place_states enable row level security;

drop policy if exists "ups_select_own_or_public"   on public.user_place_states;
drop policy if exists "ups_insert_own"             on public.user_place_states;
drop policy if exists "ups_update_own"             on public.user_place_states;
drop policy if exists "ups_delete_own"             on public.user_place_states;

create policy "ups_select_own_or_public" on public.user_place_states for select to anon, authenticated
  using (
    (auth.uid() = user_id)
    or (not is_private and exists (
        select 1 from public.profiles p
        where p.id = user_place_states.user_id and p.is_public
    ))
  );
create policy "ups_insert_own" on public.user_place_states for insert to authenticated
  with check (auth.uid() = user_id);
create policy "ups_update_own" on public.user_place_states for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "ups_delete_own" on public.user_place_states for delete to authenticated
  using (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────────────
-- 6.  FUNCIÓN RPC: match entre amigos
--     "Mi amiga ya fue a N lugares que yo quiero"
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.match_with_user(other_handle text)
returns table (
  place_id     int,
  place_name   text,
  state_name   text,
  image_url    text,
  their_state  public.place_state,
  my_state     public.place_state
)
language sql
security invoker
stable
as $$
  with me as (select auth.uid() as uid),
       them as (select id from public.profiles where handle = other_handle)
  select
    p.id, p.name, s.name, p.image_url,
    them_ups.state, my_ups.state
  from public.places p
  join public.states s on s.id = p.state_id
  join public.user_place_states them_ups on them_ups.place_id = p.id
    and them_ups.user_id = (select id from them)
    and not them_ups.is_private
  left join public.user_place_states my_ups on my_ups.place_id = p.id
    and my_ups.user_id = (select uid from me)
  -- "ellos visitaron lo que yo quiero" o "yo visité lo que ellos quieren"
  where (them_ups.state in ('visited','loved') and my_ups.state = 'wanted')
     or (them_ups.state = 'wanted' and my_ups.state in ('visited','loved'))
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 6b. FUNCIÓN RPC: ranking de viajeros
--     Tabla pública con conteos visited/loved/wanted por usuario
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.leaderboard()
returns table (
  handle        text,
  avatar_seed   text,
  visited_count bigint,
  loved_count   bigint,
  wanted_count  bigint,
  total_marked  bigint
)
language sql
security invoker
stable
as $$
  select
    pr.handle,
    pr.avatar_seed,
    count(*) filter (where ups.state = 'visited')              as visited_count,
    count(*) filter (where ups.state = 'loved')                as loved_count,
    count(*) filter (where ups.state = 'wanted')               as wanted_count,
    count(*)                                                    as total_marked
  from public.profiles pr
  join public.user_place_states ups on ups.user_id = pr.id
    and not ups.is_private
  where pr.is_public
  group by pr.handle, pr.avatar_seed
  order by (count(*) filter (where ups.state in ('visited','loved'))) desc,
           total_marked desc
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 7.  SEED DE ESTADOS  (mapeo región para los 32)
-- ─────────────────────────────────────────────────────────────────────

insert into public.states (id, clave, slug, name, region, image_url, link, lat, lng) values
  (468,   'AGU', 'aguascalientes',      'Aguascalientes',       'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/02/basilica-de-la-virgen-de-la-asuncion-ciudad-de-aguascalientes-1-450x281.jpg', 'https://escapadas.mexicodesconocido.com.mx/aguascalientes/',  21.8852562, -102.2915677),
  (470,   'BCN', 'baja-california',     'Baja California',      'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/10/tijuana-baja-california-mexico-450x281.jpg',                                              'https://escapadas.mexicodesconocido.com.mx/baja-california/', 30.8406338, -115.2837585),
  (472,   'BCS', 'baja-california-sur', 'Baja California Sur',  'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/03/destinos-alrededores-la-paz-bcs-cabos-900x360-2-450x180.jpg',                              'https://escapadas.mexicodesconocido.com.mx/baja-california-sur/', 26.0444446, -111.6660725),
  (474,   'CAM', 'campeche',            'Campeche',             'Península',  'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/07/campeche-450x281.jpg',                                                                       'https://escapadas.mexicodesconocido.com.mx/campeche/',        19.8301251,  -90.5349087),
  (476,   'CHP', 'chiapas',             'Chiapas',              'Sur',        'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2023/06/CHIAPAS-PORTADA-ESCAPADAS-2560x1673-ENCRUCIJADA-JUN23-450x294.jpg',                          'https://escapadas.mexicodesconocido.com.mx/chiapas/',          16.7569318,  -93.1292353),
  (478,   'CHH', 'chihuahua',           'Chihuahua',            'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/10/9-Chepe_Chih_Cortesia-Sectur-Chih-450x331.jpg',                                              'https://escapadas.mexicodesconocido.com.mx/chihuahua/',        28.6339090, -106.0706130),
  (11358, 'CMX', 'ciudad-de-mexico',    'Ciudad de México',     'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2022/07/Ciudad-de-Mexico-450x253.jpg',                                                              'https://escapadas.mexicodesconocido.com.mx/ciudad-de-mexico/', 19.4326077, -99.1332080),
  (480,   'COA', 'coahuila',            'Coahuila',             'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/01/dino-450x300.png',                                                                          'https://escapadas.mexicodesconocido.com.mx/coahuila/',         25.4153192, -100.9946016),
  (482,   'COL', 'colima',              'Colima',               'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/10/volcan-de-fuego-comala-ok-450x299.jpg',                                                      'https://escapadas.mexicodesconocido.com.mx/colima/',           19.2433892, -103.7285609),
  (484,   'DUR', 'durango',             'Durango',              'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/01/durango-450x279.jpg',                                                                       'https://escapadas.mexicodesconocido.com.mx/durango/',          24.0277202, -104.6531759),
  (486,   'MEX', 'estado-de-mexico',    'Estado de México',     'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/03/Cascada-Congelada_Tlalmanalco-foto-MLA_ok-450x299.jpg',                                       'https://escapadas.mexicodesconocido.com.mx/estado-de-mexico/', 19.4968732,  -99.7232673),
  (488,   'GUA', 'guanajuato',          'Guanajuato',           'Bajío',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Guanajuato1-450x253.png',                                                                    'https://escapadas.mexicodesconocido.com.mx/guanajuato/',       21.0190145, -101.2573586),
  (490,   'GRO', 'guerrero',            'Guerrero',             'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/guerrero-2-450x253.png',                                                                     'https://escapadas.mexicodesconocido.com.mx/guerrero/',         17.4391926,  -99.5450974),
  (492,   'HID', 'hidalgo',             'Hidalgo',              'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/10/HGO_HUASCA-DE-OCAMPO-PRISMAS-BASALTICOS-CASCADA-Y-PUENTE_20140522_1649_RCmd-1-450x300.jpg', 'https://escapadas.mexicodesconocido.com.mx/hidalgo/',          20.0911253,  -98.7624145),
  (494,   'JAL', 'jalisco',             'Jalisco',              'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/roman-lopez-cGOkS_UvttU-unsplash-450x360.jpg',                                                'https://escapadas.mexicodesconocido.com.mx/jalisco/',          21.9911111, -103.2344444),
  (496,   'MIC', 'michoacan',           'Michoacán',            'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/03/templo_del_carmen_morelia_BO_md-450x281.jpeg',                                               'https://escapadas.mexicodesconocido.com.mx/michoacan/',        19.6951596, -101.2793050),
  (498,   'MOR', 'morelos',             'Morelos',              'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/10/balnearios_morelos_xochitepec_MLA-450x299.jpg',                                              'https://escapadas.mexicodesconocido.com.mx/morelos/',          18.6813049,  -99.1013498),
  (500,   'NAY', 'nayarit',             'Nayarit',              'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2022/06/imagen-intro-estado-nayarit-450x253.jpg',                                                    'https://escapadas.mexicodesconocido.com.mx/nayarit/',          21.5120274, -104.8915286),
  (502,   'NLE', 'nuevo-leon',          'Nuevo León',           'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/NuevoLeon-450x253.png',                                                                      'https://escapadas.mexicodesconocido.com.mx/nuevo-leon/',       25.5921720,  -99.9961947),
  (504,   'OAX', 'oaxaca',              'Oaxaca',               'Sur',        'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/8064918386_e08b860955_o-450x299.jpg',                                                        'https://escapadas.mexicodesconocido.com.mx/oaxaca/',           17.0731842,  -96.7265889),
  (506,   'PUE', 'puebla',              'Puebla',               'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2025/11/1920x1008_OPEN-GRAPH_nuevo-450x236.jpg',                                                    'https://escapadas.mexicodesconocido.com.mx/puebla/',           19.0414398,  -98.2062727),
  (508,   'QUE', 'queretaro',           'Querétaro',            'Bajío',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Arcos1726_Queretaro_Foto-Yarhim-Jimenez-450x282.jpg',                                        'https://escapadas.mexicodesconocido.com.mx/queretaro/',        20.5887932, -100.3898881),
  (510,   'ROO', 'quintana-roo',        'Quintana Roo',         'Península',  'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/02/1600x100-foto-playa-Cancun-450x281.jpg',                                                    'https://escapadas.mexicodesconocido.com.mx/quintana-roo/',     18.6581370,  -88.4056686),
  (512,   'SLP', 'san-luis-potosi',     'San Luis Potosí',      'Bajío',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Depositphotos_Centro-Historico-San-Luis-Potosi-450x300.jpg',                                'https://escapadas.mexicodesconocido.com.mx/san-luis-potosi/',  22.1564699, -100.9855409),
  (514,   'SIN', 'sinaloa',             'Sinaloa',              'Pacífico',   'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2023/11/SINALOA-2-450x253.jpg',                                                                     'https://escapadas.mexicodesconocido.com.mx/sinaloa/',          25.1721091, -107.4795173),
  (516,   'SON', 'sonora',              'Sonora',               'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2023/03/portada-escapadas-PESCA-1-450x294.jpg',                                                      'https://escapadas.mexicodesconocido.com.mx/sonora/',           29.2972247, -110.3308814),
  (518,   'TAB', 'tabasco',             'Tabasco',              'Sur',        'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Depositphotos_Cabeza-Olmeca-Tabasco-1-450x246.jpg',                                          'https://escapadas.mexicodesconocido.com.mx/tabasco/',          17.8409173,  -92.6189273),
  (520,   'TAM', 'tamaulipas',          'Tamaulipas',           'Norte',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/cuerudo-tamaulipeco_Cortesia-Francisco-Hernandez-via-Instagram-450x338.jpg',                  'https://escapadas.mexicodesconocido.com.mx/tamaulipas/',       24.2669400,  -98.8362755),
  (522,   'TLA', 'tlaxcala',            'tlaxcala',             'Centro',     'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2023/06/TLAXCALA-PORTADA-2560X1673-2-450x294.jpg',                                                  'https://escapadas.mexicodesconocido.com.mx/tlaxcala/',         19.3181540,  -98.2374954),
  (524,   'VER', 'veracruz',            'Veracruz',             'Sur',        'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2021/03/3494-GEMD-Veracruz-Primeros-Pasos-de-Cortes-Puerto-de-Veracruz-Catedral-de-Nuestra-Senora-de-la-Asuncion-GP-Hi-450x675.jpg', 'https://escapadas.mexicodesconocido.com.mx/veracruz/', 19.1737730,  -96.1342241),
  (526,   'YUC', 'yucatan',             'Yucatán',              'Península',  'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Merida-monumento-a-la-patria_Paseo-Montejo-450x312.jpg',                                     'https://escapadas.mexicodesconocido.com.mx/yucatan/',          20.9670266,  -89.6237199),
  (528,   'ZAC', 'zacatecas',           'zacatecas',            'Bajío',      'https://escapadas.mexicodesconocido.com.mx/wp-content/uploads/2020/12/Teleferico-Zacatecas-1-450x338.jpg',                                                        'https://escapadas.mexicodesconocido.com.mx/zacatecas/',        22.7709249, -102.5832539)
on conflict (id) do update set
  region    = excluded.region,
  image_url = excluded.image_url,
  link      = excluded.link,
  lat       = excluded.lat,
  lng       = excluded.lng;

-- ─────────────────────────────────────────────────────────────────────
-- 8.  CÓMO CARGAR LOS DESTINOS (~250)
-- ─────────────────────────────────────────────────────────────────────
-- Los destinos se cargan con el script Node `seed-places.mjs` que viene
-- en el zip. Lee tu escapadas-index.json y hace upsert en lotes.
--
-- Alternativa manual: usa la UI de Supabase → Table Editor → places →
-- Import data from CSV (genera el CSV con from_index.py --csv).
-- ─────────────────────────────────────────────────────────────────────

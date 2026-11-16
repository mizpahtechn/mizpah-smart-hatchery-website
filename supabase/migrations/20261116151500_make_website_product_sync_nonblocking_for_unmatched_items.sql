create or replace function public.sync_website_product_to_app_price_list(
  p_id text,
  p_name text,
  p_type text,
  p_price integer,
  p_published boolean,
  p_minimum_order integer,
  p_image_path text
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  affected integer;
  clean_id text := nullif(btrim(coalesce(p_id, '')), '');
  clean_name text := nullif(btrim(coalesce(p_name, '')), '');
  clean_type text := nullif(btrim(coalesce(p_type, '')), '');
  clean_image_path text := nullif(btrim(coalesce(p_image_path, '')), '');
  app_item_exists boolean;
begin
  if not public.mizpah_web_phase2_is_manager() then
    raise exception 'Authorised Mizpah website manager access is required.'
      using errcode = '42501';
  end if;

  if clean_id is null or clean_name is null or clean_type is null
     or p_price is null or p_price <= 0
     or p_minimum_order is null or p_minimum_order < 1 then
    raise exception 'A valid product ID, name, category, positive price and minimum order are required.';
  end if;

  select exists (
    select 1 from public.price_list_items where id = clean_id
  ) into app_item_exists;

  -- Existing app items can be updated regardless of their display name.
  -- New app items are created only when the approved Mizpah naming and
  -- Flutter image-path requirements are satisfied. Otherwise website save
  -- succeeds and this function reports that no app sync was performed.
  if not app_item_exists and (
    lower(clean_name) not like 'mizpah %' or clean_image_path is null
  ) then
    return false;
  end if;

  if app_item_exists then
    update public.price_list_items
       set name = clean_name,
           type = clean_type,
           price = p_price,
           image_path = coalesce(clean_image_path, image_path),
           available = true,
           minimum_order = p_minimum_order,
           published = coalesce(p_published, false),
           updated_at = now(),
           source = 'Mizpah Website Admin'
     where id = clean_id;
    get diagnostics affected = row_count;
  else
    insert into public.price_list_items
      (id,name,type,price,image_path,available,minimum_order,published,updated_at,source)
    values
      (clean_id,clean_name,clean_type,p_price,clean_image_path,true,p_minimum_order,
       coalesce(p_published,false),now(),'Mizpah Website Admin')
    on conflict (id) do update
      set name = excluded.name,
          type = excluded.type,
          price = excluded.price,
          image_path = coalesce(clean_image_path, public.price_list_items.image_path),
          available = true,
          minimum_order = excluded.minimum_order,
          published = excluded.published,
          updated_at = now(),
          source = 'Mizpah Website Admin';
    get diagnostics affected = row_count;
  end if;

  return affected > 0;
end;
$function$;

-- ApnaCircle Seed Data - Phase 2
-- Seeds cities and categories from packages/types/data/

-- =============================================================================
-- CITIES (from packages/types/data/cities.json)
-- =============================================================================

insert into public.cities (slug, name, state, country, active, rollout_order, timezone) values
  ('saharanpur', 'Saharanpur', 'Uttar Pradesh', 'IN', true, 1, 'Asia/Kolkata'),
  ('roorkee', 'Roorkee', 'Uttarakhand', 'IN', false, 2, 'Asia/Kolkata'),
  ('muzaffarnagar', 'Muzaffarnagar', 'Uttar Pradesh', 'IN', false, 2, 'Asia/Kolkata'),
  ('haridwar', 'Haridwar', 'Uttarakhand', 'IN', false, 3, 'Asia/Kolkata'),
  ('dehradun', 'Dehradun', 'Uttarakhand', 'IN', false, 3, 'Asia/Kolkata'),
  ('meerut', 'Meerut', 'Uttar Pradesh', 'IN', false, 4, 'Asia/Kolkata')
on conflict (slug) do update set
  name = excluded.name,
  state = excluded.state,
  country = excluded.country,
  active = excluded.active,
  rollout_order = excluded.rollout_order,
  timezone = excluded.timezone;

-- =============================================================================
-- CATEGORIES (from packages/types/data/categories.json)
-- =============================================================================

insert into public.categories (slug, name, featured_route, kind) values
  ('places-to-visit', 'Places to Visit', true, 'place'),
  ('cafes-and-restaurants', 'Cafes & Restaurants', true, 'place'),
  ('parks-and-outdoor-spaces', 'Parks & Outdoor Spaces', false, 'place'),
  ('photography-spots', 'Photography Spots', true, 'place'),
  ('historical-places', 'Historical Places', false, 'place'),
  ('shopping-and-markets', 'Shopping & Markets', false, 'place'),
  ('weekend-activities', 'Weekend Activities', true, 'activity'),
  ('sports-and-fitness', 'Sports & Fitness', false, 'activity'),
  ('food-exploration', 'Food Exploration', false, 'activity'),
  ('tech-and-professional-communities', 'Tech & Professional Communities', false, 'activity'),
  ('arts-music-and-hobbies', 'Arts, Music & Hobbies', false, 'activity')
on conflict (slug) do update set
  name = excluded.name,
  featured_route = excluded.featured_route,
  kind = excluded.kind;

-- =============================================================================
-- INTERESTS (derived from categories for onboarding)
-- =============================================================================

-- Place interests
insert into public.interests (slug, name, category_id) values
  ('monuments', 'Monuments', (select id from public.categories where slug = 'historical-places')),
  ('temples', 'Temples', (select id from public.categories where slug = 'historical-places')),
  ('museums', 'Museums', (select id from public.categories where slug = 'historical-places')),
  ('cafes', 'Cafes', (select id from public.categories where slug = 'cafes-and-restaurants')),
  ('fine-dining', 'Fine Dining', (select id from public.categories where slug = 'cafes-and-restaurants')),
  ('street-food', 'Street Food', (select id from public.categories where slug = 'cafes-and-restaurants')),
  ('parks', 'Parks', (select id from public.categories where slug = 'parks-and-outdoor-spaces')),
  ('gardens', 'Gardens', (select id from public.categories where slug = 'parks-and-outdoor-spaces')),
  ('hiking-trails', 'Hiking Trails', (select id from public.categories where slug = 'parks-and-outdoor-spaces')),
  ('photography', 'Photography', (select id from public.categories where slug = 'photography-spots')),
  ('sunset-spots', 'Sunset Spots', (select id from public.categories where slug = 'photography-spots')),
  ('architecture', 'Architecture', (select id from public.categories where slug = 'photography-spots')),
  ('markets', 'Markets', (select id from public.categories where slug = 'shopping-and-markets')),
  ('handicrafts', 'Handicrafts', (select id from public.categories where slug = 'shopping-and-markets')),
  ('local-shopping', 'Local Shopping', (select id from public.categories where slug = 'shopping-and-markets')),
  ('sightseeing', 'Sightseeing', (select id from public.categories where slug = 'places-to-visit')),
  ('day-trips', 'Day Trips', (select id from public.categories where slug = 'places-to-visit')),
  ('hidden-gems', 'Hidden Gems', (select id from public.categories where slug = 'places-to-visit'))
on conflict (slug) do update set
  name = excluded.name,
  category_id = excluded.category_id;

-- Activity interests
insert into public.interests (slug, name, category_id) values
  ('weekend-getaways', 'Weekend Getaways', (select id from public.categories where slug = 'weekend-activities')),
  ('events', 'Events', (select id from public.categories where slug = 'weekend-activities')),
  ('group-activities', 'Group Activities', (select id from public.categories where slug = 'weekend-activities')),
  ('running', 'Running', (select id from public.categories where slug = 'sports-and-fitness')),
  ('cycling', 'Cycling', (select id from public.categories where slug = 'sports-and-fitness')),
  ('yoga', 'Yoga', (select id from public.categories where slug = 'sports-and-fitness')),
  ('gym', 'Gym', (select id from public.categories where slug = 'sports-and-fitness')),
  ('food-tours', 'Food Tours', (select id from public.categories where slug = 'food-exploration')),
  ('cooking-classes', 'Cooking Classes', (select id from public.categories where slug = 'food-exploration')),
  ('food-festivals', 'Food Festivals', (select id from public.categories where slug = 'food-exploration')),
  ('tech-meetups', 'Tech Meetups', (select id from public.categories where slug = 'tech-and-professional-communities')),
  ('networking', 'Networking', (select id from public.categories where slug = 'tech-and-professional-communities')),
  ('workshops', 'Workshops', (select id from public.categories where slug = 'tech-and-professional-communities')),
  ('art-classes', 'Art Classes', (select id from public.categories where slug = 'arts-music-and-hobbies')),
  ('music-events', 'Music Events', (select id from public.categories where slug = 'arts-music-and-hobbies')),
  ('hobby-groups', 'Hobby Groups', (select id from public.categories where slug = 'arts-music-and-hobbies'))
on conflict (slug) do update set
  name = excluded.name,
  category_id = excluded.category_id;
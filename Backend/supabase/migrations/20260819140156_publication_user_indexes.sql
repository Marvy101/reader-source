create index if not exists publication_chunks_user_publication
  on public.publication_chunks (user_id, publication_id);

create index if not exists publication_annotations_user_publication
  on public.publication_annotations (user_id, publication_id);

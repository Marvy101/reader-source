import type { SupabaseClient } from "@supabase/supabase-js";

export type BookPassage = {
  ordinal: number;
  resourceId: string;
  resourceTitle: string | null;
  text: string;
  positionStart: number;
  positionEnd: number;
  progressionStart: number;
  progressionEnd: number;
};

export type BookAnnotation = {
  id: string;
  selectedText: string;
  note: string | null;
  resourceId: string;
  progression: number;
  locator: Record<string, unknown>;
};

export interface BookKnowledgeSearching {
  loadPage(publicationId: string, currentProgression: number): Promise<BookPassage[]>;
  loadWholeBook(publicationId: string, maximumProgression: number): Promise<BookPassage[]>;
  searchBook(
    publicationId: string,
    query: string,
    maximumProgression: number,
    limit: number,
  ): Promise<BookPassage[]>;
  searchAnnotations(
    publicationId: string,
    query: string,
    maximumProgression: number,
    limit: number,
  ): Promise<BookAnnotation[]>;
}

export class SupabaseBookKnowledgeStore implements BookKnowledgeSearching {
  constructor(private readonly client: SupabaseClient) {}

  async loadPage(
    publicationId: string,
    currentProgression: number,
  ): Promise<BookPassage[]> {
    const progression = Math.min(Math.max(currentProgression, 0), 1);
    const { data, error } = await this.client
      .from("publication_chunks")
      .select(
        "ordinal,resource_id,resource_title,text,position_start,position_end,progression_start,progression_end",
      )
      .eq("publication_id", publicationId)
      .lte("progression_start", progression)
      .gte("progression_end", progression)
      .order("ordinal", { ascending: true })
      .limit(2);

    if (error) throw error;
    if ((data ?? []).length > 0) return (data ?? []).map(mapPassage);

    const { data: fallback, error: fallbackError } = await this.client
      .from("publication_chunks")
      .select(
        "ordinal,resource_id,resource_title,text,position_start,position_end,progression_start,progression_end",
      )
      .eq("publication_id", publicationId)
      .lte("progression_start", progression)
      .order("progression_start", { ascending: false })
      .limit(1);

    if (fallbackError) throw fallbackError;
    return (fallback ?? []).map(mapPassage);
  }

  async loadWholeBook(
    publicationId: string,
    maximumProgression: number,
  ): Promise<BookPassage[]> {
    const { data, error } = await this.client
      .from("publication_chunks")
      .select(
        "ordinal,resource_id,resource_title,text,position_start,position_end,progression_start,progression_end",
      )
      .eq("publication_id", publicationId)
      .lte("progression_end", maximumProgression)
      .order("ordinal", { ascending: true });

    if (error) throw error;
    return (data ?? []).map(mapPassage);
  }

  async searchBook(
    publicationId: string,
    query: string,
    maximumProgression: number,
    limit: number,
  ): Promise<BookPassage[]> {
    const { data, error } = await this.client.rpc("search_publication_chunks", {
      target_publication_id: publicationId,
      search_query: query,
      maximum_progression: maximumProgression,
      result_limit: limit,
    });

    if (error) throw error;
    return (data ?? []).map(mapPassage);
  }

  async searchAnnotations(
    publicationId: string,
    query: string,
    maximumProgression: number,
    limit: number,
  ): Promise<BookAnnotation[]> {
    const { data, error } = await this.client.rpc(
      "search_publication_annotations",
      {
        target_publication_id: publicationId,
        search_query: query,
        maximum_progression: maximumProgression,
        result_limit: limit,
      },
    );

    if (error) throw error;
    return (data ?? []).map((row: Record<string, unknown>) => ({
      id: String(row.id),
      selectedText: String(row.selected_text),
      note: row.note == null ? null : String(row.note),
      resourceId: String(row.resource_id),
      progression: Number(row.progression),
      locator: (row.locator ?? {}) as Record<string, unknown>,
    }));
  }
}

function mapPassage(row: Record<string, unknown>): BookPassage {
  return {
    ordinal: Number(row.ordinal),
    resourceId: String(row.resource_id),
    resourceTitle: row.resource_title == null ? null : String(row.resource_title),
    text: String(row.text),
    positionStart: Number(row.position_start),
    positionEnd: Number(row.position_end),
    progressionStart: Number(row.progression_start),
    progressionEnd: Number(row.progression_end),
  };
}

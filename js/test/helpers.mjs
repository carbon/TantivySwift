import { init, Index, SchemaBuilder, Analyzer } from "../dist/index.js";

await init();

/** Books: text title/body, a string id, numeric and date fields, tags. */
export function booksIndex(options) {
  const schema = new SchemaBuilder()
    .addStringField("id", { stored: true, fast: true })
    .addTextField("title", { stored: true })
    .addTextField("body")
    .addU64Field("year", { stored: true, fast: true })
    .addF64Field("rating", { stored: true, fast: true })
    .addStringField("tag", { stored: true, fast: true })
    .addDateField("published", { stored: true, fast: true })
    .build();
  const index = Index.inMemory(schema, options);
  index.addAll([
    { id: "1", title: "The Old Man and the Sea", body: "an old man fished alone in a skiff", year: 1952, rating: 4.1, tag: ["classic", "sea"], published: new Date("1952-09-01T00:00:00Z") },
    { id: "2", title: "Moby Dick", body: "the whale and the sea", year: 1851, rating: 3.9, tag: ["classic", "sea"], published: new Date("1851-10-18T00:00:00Z") },
    { id: "3", title: "Dune", body: "desert planet and spice", year: 1965, rating: 4.3, tag: "scifi", published: new Date("1965-08-01T00:00:00Z") },
    { id: "4", title: "Neuromancer", body: "the sky above the port", year: 1984, rating: 3.8, tag: "scifi", published: new Date("1984-07-01T00:00:00Z") },
  ]);
  return index;
}

export function titles(hits) {
  return hits.map((h) => h.string("title"));
}

export { Analyzer };

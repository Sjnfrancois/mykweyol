# my kwéyòl

Open `Palapata.xcodeproj` in Xcode and run the **Palapata** scheme on an iPhone with iOS 17 or later.

The app starts with an empty vocabulary. Words, collections, review dates, and preferences are saved locally in the app's Application Support directory. No account or network connection is required.

## What works

- Add, edit, browse, search, filter, sort, and delete words. A spelling can have several related meanings and separate unrelated entries. Each meaning keeps its own English gloss, part of speech, example pair, collections, and learning progress.
- Record pronunciation with the microphone, preview it, save or replace it, and play it from word details or review. Audio is never synthesized.
- Create, edit, search, and delete collections. Deleting a collection keeps its words. Add existing words from a collection's **Add words** button; long press a word in that collection to remove it.
- Learn new meanings from selected collections, then review due meanings independently. When a spelling has several meanings, learning and review cards show the target meaning's part of speech and example as context. Due reviews are never filtered by the selected learning collections.
- Reveal each review answer, choose **Got It** or **Missed It**, and see session totals and next review dates. Missed meanings return later in the same session.
- Import the first worksheet of an `.xlsx` file. Map columns, preview each sense, and choose a bulk action such as **Add New + Update Existing**. The importer supports shared strings and inline text. Supported headers are `Kweyol`, `Homonym`, `Part of Speech`, `Sense`, `English`, `Pronunciation`, `Example Kweyol`, `Example English`, and `Collections`. Map alternate headers in the app. `Kweyol` and `English` are required; blank `Homonym` and `Sense` values default to 1. Separate names in `Collections` with **semicolons** (`Food; Nouns; Top 1,000`); commas are part of a collection name.
- Import identity is the case-insensitive spelling plus homonym number plus sense number. Updating a matching sense appends collections and preserves audio and review progress. Older combined meanings with ambiguous progress are retained as an earlier saved meaning when a structured import cannot match their English gloss exactly.
- Export a JSON backup containing words, collections, preferences, review progress, and recorded audio. Reset review progress without deleting vocabulary. Settings also has a confirmed **Clear all words** action; collections stay unless **Also clear collections** is selected. Saved sentences remain.

Microphone access is requested only when recording starts. The bundled DM Sans Black font and its license are in `Palapata/Fonts/`. The `Previews/` directory contains captures of the original visual prototype.

# Reading without breaking concentration

A small desktop translator can help a reader understand an unfamiliar paragraph without leaving the document. The selected passage may contain an introduction, several headings, a numbered explanation, and a short conclusion. These boundaries carry meaning. A useful translation keeps them visible so the reader can compare the explanation with the original and return to the document without losing their place.

## Text that arrives gradually

Streaming makes the waiting period easier to understand. The first translated words appear as soon as the model produces them, and the remaining sentences continue to arrive in order. The application keeps the current reading position stable while new material is added. A progress indicator remains visible until the response is complete, so a partial sentence is never mistaken for the finished result.

1. **Keep the structure:** a heading stays above the paragraph it introduces, and each numbered item stays separate from the next item.
    - A nested example remains indented beneath its parent item, even when the translation takes a different number of characters.
    - A second example preserves the same relationship and uses the same comfortable text size.
2. **Handle interruptions:** closing the window cancels the current request. Starting another translation creates a separate request whose output cannot be overwritten by an earlier response.
3. **Check the finished result:** once generation ends, the application checks that every source paragraph has a corresponding translation and that important inline formatting has survived.

The final translation can then be copied for personal reading. If the connection fails, the window explains the problem and offers a retry. The reader should always be able to tell whether the application is waiting, generating a preview, or showing a completed translation.

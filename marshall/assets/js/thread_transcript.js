/**
 * Keep the browser viewport stable while LiveView appends transcript events.
 * LiveView patches can otherwise move focus and scroll the page to the stream.
 */
export const ThreadTranscript = {
  beforeUpdate() {
    this.scrollX = window.scrollX;
    this.scrollY = window.scrollY;
  },

  updated() {
    window.scrollTo(this.scrollX ?? window.scrollX, this.scrollY ?? window.scrollY);
  },
};

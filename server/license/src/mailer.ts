// Delivers license keys to buyers.

export interface LicenseEmail {
  to: string;
  licenseKey: string;
  seats: number;
}

export interface Mailer {
  sendLicense(email: LicenseEmail): Promise<void>;
}

export function licenseEmailBody({ licenseKey, seats }: LicenseEmail): { subject: string; text: string } {
  const link = `glint://activate?key=${encodeURIComponent(licenseKey)}`;
  return {
    subject: "Your Glint Pro license",
    text: [
      "Thank you for buying Glint Pro.",
      "",
      `Click to activate on this Mac: ${link}`,
      "",
      "Or paste this key in Glint › Settings › License:",
      licenseKey,
      "",
      `It works on up to ${seats} Macs for every 1.x release. You can free a seat from Glint's settings or at /seats on this server.`,
    ].join("\n"),
  };
}

/** Logs instead of sending. Used until an email provider is configured, and in tests. */
export class ConsoleMailer implements Mailer {
  readonly sent: LicenseEmail[] = [];

  async sendLicense(email: LicenseEmail): Promise<void> {
    this.sent.push(email);
    // Never log the email address or the key.
    console.log(`License email queued (${email.seats} seats)`);
  }
}

/** Sends through Resend's HTTP API when `RESEND_API_KEY` is set. */
export class ResendMailer implements Mailer {
  private readonly apiKey: string;
  private readonly from: string;

  constructor(apiKey: string, from: string) {
    this.apiKey = apiKey;
    this.from = from;
  }

  async sendLicense(email: LicenseEmail): Promise<void> {
    const { subject, text } = licenseEmailBody(email);
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${this.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: this.from, to: [email.to], subject, text }),
    });
    if (!response.ok) throw new Error(`Email provider returned ${response.status}`);
  }
}

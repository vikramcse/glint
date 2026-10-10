// D1 access. Rows hold license ids, email hashes and random install ids only.

export interface LicenseRow {
  id: string;
  email_hash: string;
  seats: number;
  provider: string | null;
  order_id: string | null;
  created_at: number;
}

export interface ActivationRow {
  license_id: string;
  install_id: string;
  activated_at: number;
  last_seen_at: number;
}

export class LicenseStore {
  private readonly db: D1Database;

  constructor(db: D1Database) {
    this.db = db;
  }

  license(id: string): Promise<LicenseRow | null> {
    return this.db.prepare("SELECT * FROM licenses WHERE id = ?").bind(id).first<LicenseRow>();
  }

  licenseForOrder(orderID: string): Promise<LicenseRow | null> {
    return this.db.prepare("SELECT * FROM licenses WHERE order_id = ?").bind(orderID).first<LicenseRow>();
  }

  async insertLicense(row: LicenseRow): Promise<void> {
    await this.db
      .prepare("INSERT OR IGNORE INTO licenses (id, email_hash, seats, provider, order_id, created_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(row.id, row.email_hash, row.seats, row.provider, row.order_id, row.created_at)
      .run();
  }

  async activations(licenseID: string): Promise<ActivationRow[]> {
    const result = await this.db
      .prepare("SELECT * FROM activations WHERE license_id = ? ORDER BY activated_at")
      .bind(licenseID)
      .all<ActivationRow>();
    return result.results;
  }

  /**
   * Adds or refreshes a seat. Returns false when the license already uses every seat.
   * The count and insert run as one statement so two Macs racing for the last seat cannot
   * both win.
   */
  async claimSeat(licenseID: string, installID: string, seats: number, now: number): Promise<boolean> {
    const existing = await this.db
      .prepare("UPDATE activations SET last_seen_at = ? WHERE license_id = ? AND install_id = ?")
      .bind(now, licenseID, installID)
      .run();
    if (existing.meta.changes > 0) return true;
    const inserted = await this.db
      .prepare(
        `INSERT INTO activations (license_id, install_id, activated_at, last_seen_at)
         SELECT ?1, ?2, ?3, ?3
         WHERE (SELECT COUNT(*) FROM activations WHERE license_id = ?1) < ?4`,
      )
      .bind(licenseID, installID, now, seats)
      .run();
    return inserted.meta.changes > 0;
  }

  async releaseSeat(licenseID: string, installID: string): Promise<boolean> {
    const result = await this.db
      .prepare("DELETE FROM activations WHERE license_id = ? AND install_id = ?")
      .bind(licenseID, installID)
      .run();
    return result.meta.changes > 0;
  }

  async touch(licenseID: string, installID: string, now: number): Promise<void> {
    await this.db
      .prepare("UPDATE activations SET last_seen_at = ? WHERE license_id = ? AND install_id = ?")
      .bind(now, licenseID, installID)
      .run();
  }

  async isRevoked(licenseID: string): Promise<boolean> {
    const row = await this.db.prepare("SELECT 1 AS revoked FROM revocations WHERE license_id = ?").bind(licenseID).first();
    return row !== null;
  }

  async revoke(licenseID: string, reason: string, now: number): Promise<void> {
    await this.db
      .prepare("INSERT OR IGNORE INTO revocations (license_id, reason, revoked_at) VALUES (?, ?, ?)")
      .bind(licenseID, reason, now)
      .run();
  }

  /** Records a webhook delivery; returns false if it was already processed. */
  async markEventProcessed(id: string, now: number): Promise<boolean> {
    const result = await this.db
      .prepare("INSERT OR IGNORE INTO webhook_events (id, received_at) VALUES (?, ?)")
      .bind(id, now)
      .run();
    return result.meta.changes > 0;
  }
}

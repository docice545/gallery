import { Injectable } from '@nestjs/common';
import { type Insertable, type Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DummyValue, GenerateSql } from 'src/decorators.js';
import { AssetOcrResponseDto } from 'src/dtos/ocr.dto.js';
import { AssetStatus, AssetVisibility } from 'src/enum.js';
import { DB } from 'src/schema/index.js';
import { AssetOcrTable } from 'src/schema/tables/asset-ocr.table.js';

@Injectable()
export class OcrRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  @GenerateSql({ params: [DummyValue.UUID] })
  getById(id: string) {
    return this.db.selectFrom('asset_ocr').selectAll('asset_ocr').where('asset_ocr.id', '=', id).executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getByAssetId(id: string, options?: { isVisible?: boolean }) {
    const isVisible = options === undefined ? true : options.isVisible;

    return this.db
      .selectFrom('asset_ocr')
      .selectAll('asset_ocr')
      .where('asset_ocr.assetId', '=', id)
      .$if(isVisible !== undefined, (qb) => qb.where('asset_ocr.isVisible', '=', isVisible!))
      .execute();
  }

  deleteAll() {
    return this.db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`truncate ${sql.table('asset_ocr')}`.execute(trx);
      await sql`truncate ${sql.table('ocr_search')}`.execute(trx);
    });
  }

  @GenerateSql({
    params: [
      DummyValue.UUID,
      [
        {
          assetId: DummyValue.UUID,
          x1: DummyValue.NUMBER,
          y1: DummyValue.NUMBER,
          x2: DummyValue.NUMBER,
          y2: DummyValue.NUMBER,
          x3: DummyValue.NUMBER,
          y3: DummyValue.NUMBER,
          x4: DummyValue.NUMBER,
          y4: DummyValue.NUMBER,
          text: DummyValue.STRING,
          boxScore: DummyValue.NUMBER,
          textScore: DummyValue.NUMBER,
        },
      ],
      DummyValue.STRING,
    ],
  })
  async upsert(assetId: string, ocrDataList: Insertable<AssetOcrTable>[], searchText: string): Promise<boolean> {
    const save = async (trx: Kysely<DB>) => {
      // OCR runs outside this transaction. Lock the parent only while replacing its results so
      // a concurrent delete either wins first (skip) or cascades after our complete commit.
      // A second existence check without this lock would still race with the child inserts.
      const asset = await trx
        .selectFrom('asset')
        .select('id')
        .where('id', '=', assetId)
        .where('deletedAt', 'is', null)
        .where('status', '=', AssetStatus.Active)
        .where('visibility', '!=', AssetVisibility.Hidden)
        .forUpdate()
        .executeTakeFirst();
      if (!asset) {
        return false;
      }

      await trx.deleteFrom('asset_ocr').where('assetId', '=', assetId).execute();
      if (ocrDataList.length > 0) {
        await trx.insertInto('asset_ocr').values(ocrDataList).execute();
        await trx
          .insertInto('ocr_search')
          .values({ assetId, text: searchText })
          .onConflict((oc) => oc.column('assetId').doUpdateSet((eb) => ({ text: eb.ref('excluded.text') })))
          .execute();
      } else {
        await trx.deleteFrom('ocr_search').where('assetId', '=', assetId).execute();
      }

      // Keep the completion marker in the same transaction as both result tables. Other jobs'
      // status columns remain unchanged, and a failure rolls back the previous OCR replacement.
      await trx
        .insertInto('asset_job_status')
        .values({ assetId, ocrAt: new Date() })
        .onConflict((oc) => oc.column('assetId').doUpdateSet((eb) => ({ ocrAt: eb.ref('excluded.ocrAt') })))
        .execute();
      return true;
    };

    return this.db.isTransaction ? save(this.db) : this.db.transaction().execute(save);
  }

  @GenerateSql({ params: [DummyValue.UUID, [], []] })
  async updateOcrVisibilities(
    assetId: string,
    visible: AssetOcrResponseDto[],
    hidden: AssetOcrResponseDto[],
  ): Promise<void> {
    await this.db.transaction().execute(async (trx) => {
      if (visible.length > 0) {
        await trx
          .updateTable('asset_ocr')
          .set({ isVisible: true })
          .where(
            'asset_ocr.id',
            'in',
            visible.map((i) => i.id),
          )
          .execute();
      }

      if (hidden.length > 0) {
        await trx
          .updateTable('asset_ocr')
          .set({ isVisible: false })
          .where(
            'asset_ocr.id',
            'in',
            hidden.map((i) => i.id),
          )
          .execute();
      }

      const searchText = visible.map((item) => item.text.trim()).join(' ');
      await trx.updateTable('ocr_search').set({ text: searchText }).where('assetId', '=', assetId).execute();
    });
  }
}

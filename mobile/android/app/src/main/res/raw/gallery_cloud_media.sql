-- Read-only picker projection of the existing Photos visibility contract.
-- Keep the owner hide/subtraction arms in sync with merged_asset.drift.
-- No auth, media mirror, migrations or writes to Gallery's database.
SELECT rae.id AS asset_id, rae.name, rae.type, rae.owner_id, rae.checksum,
  rae.updated_at, rae.created_at, rae.live_photo_video_id, rae.is_favorite,
  rae.width, rae.height, COALESCE(rae.duration_ms, 0) AS duration_ms,
  exif.file_size, exif.orientation,
  CAST(ROUND((JULIANDAY(rae.created_at) - 2440587.5) * 86400000) AS INTEGER) AS date_taken_millis,
  CASE WHEN rae.owner_id = ?1 THEN
    (SELECT lae.id FROM local_asset_entity lae
      WHERE lae.checksum = rae.checksum AND lae.checksum IS NOT NULL
      ORDER BY lae.id LIMIT 1) ELSE NULL END AS local_id
FROM remote_asset_entity rae
LEFT JOIN stack_entity se ON rae.stack_id = se.id
LEFT JOIN remote_exif_entity exif ON exif.asset_id = rae.id
WHERE
	rae.deleted_at IS NULL
	AND rae.visibility = 0 -- timeline visibility
	AND (
		(
			-- A partner's asset is never filtered by MY hidden rows: the subtraction below
			-- belongs to the CALLER alone (design doc §6.4, server E10). Splitting the arm is
			-- what enforces that; correlating the legs to ?1 is not enough,
			-- because they would still be ANDed against every row in :user_ids.
			((rae.owner_id = ?1 OR rae.owner_id IN (SELECT shared_by_id FROM partner_entity WHERE shared_with_id = ?1 AND in_timeline = 1)) AND rae.owner_id != ?1)
			OR (
				rae.owner_id = ?1
				AND NOT EXISTS (
					SELECT 1 FROM shared_space_asset_entity ssa
					INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssa.space_id
					WHERE ssa.asset_id = rae.id
						AND ssm.user_id = ?1
						AND ssm.show_in_timeline = 0
				)
				AND NOT EXISTS (
					SELECT 1 FROM shared_space_library_entity ssl
					INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssl.space_id
					WHERE ssl.library_id = rae.library_id
						AND ssm.user_id = ?1
						AND ssm.show_in_timeline = 0
				)
				AND NOT EXISTS (
					SELECT 1 FROM shared_space_album_asset_entity ssaa
					INNER JOIN shared_space_album_link_entity ssal ON ssal.album_id = ssaa.album_id
					INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssal.space_id
					WHERE ssaa.asset_id = rae.id
						AND ssm.user_id = ?1
						AND (
							ssm.show_in_timeline = 0
							OR EXISTS (
								SELECT 1 FROM shared_space_album_hidden_entity ssah
								WHERE ssah.space_id = ssal.space_id
									AND ssah.album_id = ssal.album_id
									AND ssah.user_id = ?1
							)
						)
				)
			)
		)
		OR EXISTS (
			SELECT 1 FROM shared_space_asset_entity ssa
			INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssa.space_id
			WHERE ssa.asset_id = rae.id
				AND ssm.user_id = ?1
				AND ssm.show_in_timeline = 1
		)
		OR EXISTS (
			SELECT 1 FROM shared_space_library_entity ssl
			INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssl.space_id
			WHERE ssl.library_id = rae.library_id
				AND ssm.user_id = ?1
				AND ssm.show_in_timeline = 1
		)
		OR EXISTS (
			SELECT 1 FROM shared_space_album_asset_entity ssaa
			INNER JOIN shared_space_album_link_entity ssal ON ssal.album_id = ssaa.album_id
			INNER JOIN shared_space_member_entity ssm ON ssm.space_id = ssal.space_id
			WHERE ssaa.asset_id = rae.id
				AND NOT EXISTS (
					SELECT 1 FROM shared_space_album_hidden_entity ssah
					WHERE ssah.space_id = ssal.space_id
						AND ssah.album_id = ssal.album_id
						AND ssah.user_id = ?1
				)
				AND ssm.user_id = ?1
				AND ssm.show_in_timeline = 1
		)
	)
	AND (
		rae.stack_id IS NULL
		OR rae.id = se.primary_asset_id
	)
  AND rae.type IN (1, 2)
  AND exif.file_size > 0
  -- Materialize the small companion-ID set once, not a full scan per tile.
  AND rae.id NOT IN (SELECT live_photo_video_id FROM remote_asset_entity WHERE live_photo_video_id IS NOT NULL)

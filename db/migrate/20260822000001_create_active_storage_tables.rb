class CreateActiveStorageTables < ActiveRecord::Migration[8.1]
  def up
    ensure_blobs_table
    ensure_attachments_table
    ensure_variant_records_table
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Active Storage tables may predate this migration and can contain user uploads"
  end

  private

  def ensure_blobs_table
    ensure_compatible_table(
      :active_storage_blobs,
      columns: {
        key: false,
        filename: false,
        content_type: true,
        metadata: true,
        service_name: false,
        byte_size: false,
        checksum: true,
        created_at: false
      },
      indexes: [ [ [ :key ], true ] ]
    ) do
      create_table :active_storage_blobs do |t|
        t.string :key, null: false
        t.string :filename, null: false
        t.string :content_type
        t.text :metadata
        t.string :service_name, null: false
        t.bigint :byte_size, null: false
        t.string :checksum
        t.datetime :created_at, null: false

        t.index :key, unique: true
      end
    end
  end

  def ensure_attachments_table
    ensure_compatible_table(
      :active_storage_attachments,
      columns: {
        name: false,
        record_type: false,
        record_id: false,
        blob_id: false,
        created_at: false
      },
      indexes: [
        [ [ :blob_id ], false ],
        [ [ :record_type, :record_id, :name, :blob_id ], true ]
      ],
      foreign_keys: [ [ :active_storage_blobs, :blob_id ] ]
    ) do
      create_table :active_storage_attachments do |t|
        t.string :name, null: false
        t.references :record, null: false, polymorphic: true, index: false
        t.references :blob, null: false
        t.datetime :created_at, null: false

        t.index [ :record_type, :record_id, :name, :blob_id ],
          name: :index_active_storage_attachments_uniqueness,
          unique: true
        t.foreign_key :active_storage_blobs, column: :blob_id
      end
    end
  end

  def ensure_variant_records_table
    ensure_compatible_table(
      :active_storage_variant_records,
      columns: {
        blob_id: false,
        variation_digest: false
      },
      indexes: [ [ [ :blob_id, :variation_digest ], true ] ],
      foreign_keys: [ [ :active_storage_blobs, :blob_id ] ]
    ) do
      create_table :active_storage_variant_records do |t|
        t.belongs_to :blob, null: false, index: false
        t.string :variation_digest, null: false

        t.index [ :blob_id, :variation_digest ],
          name: :index_active_storage_variant_records_uniqueness,
          unique: true
        t.foreign_key :active_storage_blobs, column: :blob_id
      end
    end
  end

  def ensure_compatible_table(table_name, columns:, indexes:, foreign_keys: [])
    unless table_exists?(table_name)
      yield
      return
    end

    problems = column_problems(table_name, columns)
    problems.concat(index_problems(table_name, indexes))
    problems.concat(foreign_key_problems(table_name, foreign_keys))

    return if problems.empty?

    raise StandardError,
      "Existing #{table_name} table is incompatible: #{problems.join('; ')}. " \
      "Reconcile the existing Active Storage schema before retrying this migration."
  end

  def column_problems(table_name, expected_columns)
    actual_columns = connection.columns(table_name).index_by { |column| column.name.to_sym }

    expected_columns.filter_map do |name, nullable|
      column = actual_columns[name]

      if column.nil?
        "missing column #{name}"
      elsif column.null != nullable
        "column #{name} must be #{nullable ? 'nullable' : 'NOT NULL'}"
      end
    end
  end

  def index_problems(table_name, expected_indexes)
    expected_indexes.filter_map do |columns, unique|
      next if index_exists?(table_name, columns, unique: unique)

      qualifier = unique ? "unique " : ""
      "missing #{qualifier}index on (#{columns.join(', ')})"
    end
  end

  def foreign_key_problems(table_name, expected_foreign_keys)
    expected_foreign_keys.filter_map do |target_table, column|
      next if foreign_key_exists?(table_name, target_table, column: column)

      "missing foreign key #{column} -> #{target_table}"
    end
  end
end

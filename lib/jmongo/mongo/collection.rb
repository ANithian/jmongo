# Copyright (C) 2010 Guy Boertje

module Mongo
  module JavaImpl
    module Collection_

      private

      def name_from opts
        return unless (opts[:name] || opts['name'])
        name = opts.delete(:name) || opts.delete('name')
        name ? name.to_s : nil
      end

      def _drop_index(spec)
        name = generate_index_name(spec.is_a?(String) || spec.is_a?(Symbol) ? spec : parse_index_spec(spec))
        idx = @db.index_information(@name).values.select do |entry|
          entry['name'] == name || name == generate_index_name(entry['key'])
        end
        if idx.nil? || idx.empty?
          raise MongoDBError, "Error with drop_index command for: #{name}"
        end
        @j_collection.dropIndexes(idx.first['name'].to_s)
      end

      def _create_indexes(obj,opts = {})
        name = name_from(opts)
        field_spec = parse_index_spec(obj)
        opts[:dropDups] = opts[:drop_dups] if opts[:drop_dups]
        if obj.is_a?(String) || obj.is_a?(Symbol)
          name = obj.to_s unless name
        end
        name = generate_index_name(field_spec) unless name
        opts['name'] = name
        begin
          @j_collection.ensureIndex(to_dbobject(field_spec),to_dbobject(opts))
        rescue => e
          if opts[:dropDups] && e.message =~ /E11000/
            # NOP. If the user is intentionally dropping dups, we can ignore duplicate key errors.
          else
            msg = "Failed to create index #{field_spec.inspect} with the following error: #{e.message}"
            raise Mongo::OperationFailure, msg
          end
        end
        name
      end

      def generate_index_name(spec)
        return spec.to_s if spec.is_a?(String) || spec.is_a?(Symbol)
        indexes = []
        spec.each_pair do |field, direction|
          dir = sort_value(field,direction)
          indexes.push("#{field}_#{dir}")
        end
        indexes.join("_")
      end

      def parse_index_spec(spec)
        field_spec = Hash.new
        if spec.is_a?(String) || spec.is_a?(Symbol)
          field_spec[spec.to_s] = 1
        elsif spec.is_a?(Array) && spec.all? {|field| field.is_a?(Array) }
          spec.each do |f|
            if [Mongo::ASCENDING, Mongo::DESCENDING, Mongo::GEO2D].include?(f[1])
              field_spec[f[0].to_s] = f[1]
            else
              raise MongoArgumentError, "Invalid index field #{f[1].inspect}; " +
                "should be one of Mongo::ASCENDING (1), Mongo::DESCENDING (-1) or Mongo::GEO2D ('2d')."
            end
          end
        else
          raise MongoArgumentError, "Invalid index specification #{spec.inspect}; " +
            "should be either a string, symbol, or an array of arrays."
        end
        field_spec
      end

      def remove_documents(obj, safe=nil)
        concern = write_concern(safe)
        wr = @j_collection.remove(to_dbobject(obj), concern)
        return from_dbobject(wr.last_error(concern)) if concern.call_get_last_error
        true
      end

      ## Note: refactor when java driver fully supports continue_on_error
      def insert_documents(obj, safe=nil, continue_on_error=false)
        to_do = [obj].flatten
        concern = write_concern(safe)
        if continue_on_error
          out = []
          to_do.each do |doc|
            res = _insert_one(doc, concern)
            out << res if res
          end
          if to_do.size != out.size
            msg = "Failed to insert document #{obj.inspect}, duplicate key"
            raise(Mongo::OperationFailure, msg)
          end
        else
          begin
            @j_collection.insert( to_dbobject(to_do), concern )
          rescue => ex
            if ex.message =~ /E11000/
              msg = "Failed to insert document #{obj.inspect}, duplicate key"
              raise(Mongo::OperationFailure, msg)
            else
              msg = "Failed to insert document #{obj.inspect} db error: #{ex.message}"
              raise Mongo::MongoDBError, msg
            end
          end
        end
        to_do
      end

      def _insert_one(obj, concern)
        one_obj = [obj].flatten.first
        dbo = to_dbobject(one_obj)
        begin
          jres = @j_collection.insert( dbo, concern )
          result = from_dbobject(jres.get_last_error(concern))
        rescue => ex
          if ex.message =~ /E11000/ #noop duplicate key
            result = {'err'=>ex.message}
          else
            msg = "Failed to insert document #{obj.inspect} db error: #{ex.message}"
            raise Mongo::MongoDBError, msg
          end
        end
        doc = from_dbobject(dbo)
        result["err"] =~ /E11000/ ? nil : doc
      end

      def find_and_modify_document(query,fields,sort,remove,update,new_,upsert)
        from_dbobject @j_collection.find_and_modify(to_dbobject(query),to_dbobject(fields),to_dbobject(sort),remove,to_dbobject(update),new_,upsert)
      end

      def find_one_document(spec, opts = {})
        opts[:skip] = 0
        opts[:batch_size] = -1
        opts[:limit] = 0
        doc = nil
        self.find(spec, opts) { |c| doc = c.next }
        doc
      end

      def update_documents(selector, document, upsert=false, multi=false, safe=nil)
        begin
          @j_collection.update(to_dbobject(selector),to_dbobject(document), upsert, multi, write_concern(safe))
        rescue => ex
          if ex.message =~ /E11001/
            msg = "Failed to update document #{document.inspect}, duplicate key"
            raise(Mongo::OperationFailure, msg)
          else
            msg = "Failed to update document #{document.inspect} db error: #{ex.message}"
            raise Mongo::MongoDBError, msg
          end
        end
      end

      def save_document(obj, safe=nil)
        @pk_factory.create_pk(obj)
        db_obj = to_dbobject(obj)
        concern = write_concern(safe)
        begin
          @j_collection.save( db_obj, concern )
        rescue => ex
          if ex.message =~ /E11000/
            msg = "Failed to insert document #{obj.inspect}, duplicate key"
            raise(Mongo::OperationFailure, msg)
          else
            msg = "Failed to insert document #{obj.inspect} db error: #{ex.message}"
            raise Mongo::MongoDBError, msg
          end
        end
        db_obj['_id']
      end

      # def id_nil?(obj)
      #   return true if obj.has_key?(:_id) && obj[:_id].nil?
      #   return true if obj.has_key?('_id') && obj['_id'].nil?
      #   false
      # end
    end
  end
end
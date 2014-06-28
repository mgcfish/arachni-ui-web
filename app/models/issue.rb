=begin
    Copyright 2013-2014 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

class Issue < ActiveRecord::Base
    include Extensions::Notifier

    belongs_to :scan

    has_many :comments, as: :commentable, dependent: :destroy

    validate :validate_review_options
    validate :validate_verification_steps
    validate :validate_remediation_steps

    validates_uniqueness_of :digest, scope: :scan_id

    # These can contain lots of junk characters which may blow up the SQL
    # statement (like null-bytes) so let the serializer deal with them.
    #serialize :url,           String
    #serialize :seed,          String
    #serialize :proof,         String
    #serialize :response_body, String

    serialize :references,    Hash
    serialize :remarks,       Hash
    serialize :tags,          Array
    serialize :headers,       Hash
    serialize :vector_inputs, Hash

    # Add 'request' and 'response' as strings, add 'vector_inputs'.
    # Remove 'headers' and 'audit_options'.
    FRAMEWORK_ISSUE_MAP = {
        name:                  nil,
        description:           nil,
        references:            nil,
        remedy_code:           nil,
        remedy_guidance:       nil,
        digest:                nil,
        cwe:                   nil,
        tags:                  nil,
        vector_type:           { vector:     :type },
        url:                   { vector:     :action },
        severity:              { severity:   { to_s:  :capitalize } },
        signature:             { variations: { first: :signature } },
        proof:                 { variations: { first: :proof } },
        requires_verification: { variations: { first: :untrusted? } },
        remarks:               { variations: { first: :remarks } },
        http_method:           { variations: { first: { vector:   :method } } },
        vector_name:           { variations: { first: { vector:   :affected_input_name } } },
        seed:                  { variations: { first: { vector:   :affected_input_value } } },
        response_body:         { variations: { first: { response: :body } } },
        response:              { variations: { first: { response: :to_s } } },
        request:               { variations: { first: { request:  :to_s } } }
    }

    ORDERED_SEVERITIES = [
        Arachni::Issue::Severity::HIGH.to_s.capitalize,
        Arachni::Issue::Severity::MEDIUM.to_s.capitalize,
        Arachni::Issue::Severity::LOW.to_s.capitalize,
        Arachni::Issue::Severity::INFORMATIONAL.to_s.capitalize
    ]

    PROTECTED = [:remediation_steps, :verification_steps, :false_positive, :fixed]

    scope :fixed, -> { where fixed: true }
    scope :light, -> { select( column_names - %w(response_body references) ) }
    scope :false_positives, -> { where( 'false_positive = ?', true ) }
    scope :verified, -> do
        where( 'requires_verification = ? AND verified = ? AND ' +
                   'false_positive = ? AND fixed = ?', true, true, false, false )
    end
    scope :pending_verification, -> do
        where( 'requires_verification = ? AND verified = ? AND '+
                   ' false_positive = ? AND fixed = ?', true, false, false, false )
    end

    def self.order_by_severity
        ret = 'CASE'
        ORDERED_SEVERITIES.each_with_index do |p, i|
            ret << " WHEN severity = '#{p}' THEN #{i}"
        end
        ret << ' END'
    end
    scope :by_severity, -> { order order_by_severity }
    default_scope { by_severity }

    def timeline
        Notification.where( model_id: id, model_type: self.class.to_s,
                            user_id: scan.owner_id ).order( 'id desc' )
    end

    def id_name
        name.parameterize
    end

    def url
        return nil if super.to_s.empty?
        super
    end

    def seed
        return nil if super.to_s.empty?
        super
    end

    def proof
        return nil if super.to_s.empty?
        super
    end

    def response_body
        return nil if super.to_s.empty?
        super
    end

    def signature
        return nil if super.to_s.empty?
        super
    end

    def verified?
        super && !false_positive?
    end

    def pending_verification?
        requires_verification? && !verified? && !false_positive? && !fixed?
    end

    def pending_review?
        !verified && !false_positive && !requires_verification && !fixed?
    end

    def requires_verification_and_verified?
        requires_verification? && verified? && !false_positive?
    end

    def has_verification_steps?
        !verification_steps.to_s.empty?
    end

    def has_remediation_steps?
        !remediation_steps.to_s.empty?
    end

    def response_body_contains_proof?
        proof && response_body && response_body.include?( proof )
    end

    def base64_response_body
        Base64.encode64( response_body ).gsub( /\n/, '' )
    end

    def to_s
        s = "#{name} in #{vector_type.capitalize}"
        s << " input '#{vector_name}'" if vector_name
        s
    end

    def cwe_url
        return if cwe.to_s.empty?
        "http://cwe.mitre.org/data/definitions/#{cwe}.html"
    end

    def subscribers
        scan.subscribers
    end

    def family
        [scan, self]
    end

    def self.describe_notification( action )
        case action
            when :destroy
                'was deleted'
            when :update, :reviewed
                'was reviewed'
            when :verified
                'was verified'
            when :fixed
                'has an updated fixed state'
            when :false_positive
                'has an updated false positive state'
            when :requires_verification
                'has an updated manual verification state'
            when :verification_steps
                'has updated verification steps'
            when :remediation_steps
                'has updated remediation steps'
            when :commented
                'has a new comment'
        end
    end

    def self.create_from_framework_issue( issue )
        create translate_framework_issue( issue )
    end

    def self.update_from_framework_issue( issue, update_only = [] )
        h = translate_framework_issue( issue )

        return if !(i = where( digest: issue.digest ).first)

        h.delete( :requires_verification ) if i.requires_verification?

        h.reject! { |k| !update_only.include? k } if update_only.any?

        i.update_attributes( h )
    end

    def self.translate_framework_issue( issue )
        h  = {}
        FRAMEWORK_ISSUE_MAP.each do |k, v|
            val = attribute_from_framework_issue( issue, v || k )
            h[k] = val.is_a?( String ) ? val.recode : val
        end

        h.reject!{ |k, v| PROTECTED.include? k }

        h
    end

    private

    def self.attribute_from_framework_issue( issue, attribute )
        traverse_attributes( issue, FRAMEWORK_ISSUE_MAP[attribute] )
    end

    def self.traverse_attributes( object, path )
        return if object.nil?

        if path.is_a? Symbol
            return if !object.respond_to?( path )
            return object.send( path )
        end

        child_attribute = path.keys.first
        child_path      = path.values.first

        return if !object.respond_to?( child_attribute )

        traverse_attributes( object.send( child_attribute ), child_path )
    end

    def validate_review_options
        if false_positive && (requires_verification || verified)
            errors.add :false_positive, 'cannot include additional options'
        end
    end

    def validate_verification_steps
        return if ActionController::Base.helpers.strip_tags( verification_steps ) == verification_steps
        errors.add :verification_steps, 'cannot contain HTML, please use Markdown instead'
    end

    def validate_remediation_steps
        return if ActionController::Base.helpers.strip_tags( remediation_steps ) == remediation_steps
        errors.add :remediation_steps, 'cannot contain HTML, please use Markdown instead'
    end

end

require 'rspec'
require_relative '../lib/custom_check'

describe 'Custom Check Testing' do
  before do
    # Do nothing
  end

  after do
    # Do nothing
  end

  context 'when condition' do
    it 'succeeds' do
      expect(true).to be_truthy
    end
  end
end